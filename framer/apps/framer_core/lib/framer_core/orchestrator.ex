defmodule FramerCore.Orchestrator do
  @moduledoc """
  Single-job chunk orchestrator.

  Responsibilities:

    * turn a job into chunks (frame ranges) and keep the canonical queue
    * hand at most one chunk at a time to each player
    * retry a failed chunk on a *different* player, up to a limit
    * distinguish "chunk finished" from "chunk failed": a chunk that exhausts
      its retries is *not* silently counted as success (see report defect #1)
    * report job progress / final status

  A chunk carries operation, paths, range and options, so assignment is just a
  message. That is also the unit that will eventually be farmed to remote
  nodes (see `FramerCore.Dispatch`).
  """

  use GenServer
  require Logger

  alias FramerCore.Job
  alias FramerCore.Job.Chunk
  alias FramerCore.Player

  @max_retries 3
  @max_total_errors 20

  defstruct [
    :job,
    :chunk_queue,
    :active_chunks,
    :completed_chunks,
    :failed_chunks,
    :total_chunks,
    :temp_dir,
    total_errors: 0
  ]

  @type t :: %__MODULE__{
          job: Job.t() | nil,
          chunk_queue: [Chunk.t()],
          active_chunks: %{String.t() => Chunk.t()},
          completed_chunks: [Chunk.t()],
          failed_chunks: [Chunk.t()],
          total_chunks: non_neg_integer(),
          temp_dir: String.t() | nil,
          total_errors: non_neg_integer()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def pid do
    Process.whereis(__MODULE__)
  end

  @doc "Submit a job. Returns `{:ok, job_id}`."
  def submit_job(input_path, output_path, opts \\ []) do
    GenServer.call(__MODULE__, {:submit_job, input_path, output_path, opts})
  end

  @doc "Current orchestrator state (job, completed chunks, failed chunks, ...)."
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       job: nil,
       chunk_queue: [],
       active_chunks: %{},
       completed_chunks: [],
       failed_chunks: [],
       total_chunks: 0,
       temp_dir: nil,
       total_errors: 0
     }}
  end

  @impl true
  def handle_call(
        {:submit_job, _input, _output, _opts},
        _from,
        %{job: %{status: :processing}} = state
      ) do
    {:reply, {:error, :job_in_progress}, state}
  end

  def handle_call({:submit_job, input_path, output_path, opts}, _from, state) do
    case do_submit(input_path, output_path, opts, state) do
      {:ok, job_id, new_state} -> {:reply, {:ok, job_id}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_status, _from, state) do
    sorted = Enum.sort_by(state.completed_chunks, & &1.start_frame)
    failed = Enum.sort_by(state.failed_chunks, & &1.start_frame)
    {:reply, %{state | completed_chunks: sorted, failed_chunks: failed}, state}
  end

  @impl true
  def handle_info({:prefetch_request, player_id}, state) do
    cond do
      is_nil(state.job) or state.job.status != :processing ->
        {:noreply, state}

      Map.has_key?(state.active_chunks, player_id) ->
        # This player is already busy; ignore stale prefetch requests so a
        # player can never be handed two chunks at once.
        {:noreply, state}

      true ->
        {chunk, rest} = find_eligible_chunk(state.chunk_queue, player_id)

        case chunk do
          nil ->
            {:noreply, state}

          chunk ->
            Player.process_chunk(player_id, chunk)
            new_active = Map.put(state.active_chunks, player_id, chunk)
            {:noreply, %{state | chunk_queue: rest, active_chunks: new_active}}
        end
    end
  end

  def handle_info({:chunk_finished, player_id, chunk_id, result}, state) do
    case Map.get(state.active_chunks, player_id) do
      %Chunk{id: ^chunk_id} = chunk ->
        new_active = Map.delete(state.active_chunks, player_id)

        if result == :ok or match?({:ok, _}, result) do
          handle_chunk_success(chunk, state, new_active)
        else
          handle_chunk_failure(chunk, player_id, result, state, new_active)
        end

      _stale_or_missing ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.temp_dir do
      File.rm_rf(state.temp_dir)
    end

    :ok
  end

  # Submission

  defp do_submit(input_path, output_path, opts, state) do
    players = FramerCore.PlayerPool.players()

    if players == [] do
      {:error, :no_workers}
    else
      if state.temp_dir, do: File.rm_rf(state.temp_dir)

      total_frames = to_int(opts[:total_frames]) || 0

      if total_frames <= 0 do
        {:error, :unknown_frame_count}
      else
        temp_dir = Path.join(System.tmp_dir!(), "framer_job_#{UUID.uuid4()}")
        File.mkdir_p!(temp_dir)

        fps = to_float(opts[:fps]) || 30.0
        operation = to_string(opts[:operation] || "transcode")
        options = opts[:options] || %{}

        chunk_size = chunk_size(opts[:chunk_size], total_frames, length(players), operation)

        job = %Job{
          id: UUID.uuid4(),
          input_path: input_path,
          output_path: output_path,
          operation: operation,
          options: options,
          total_frames: total_frames,
          chunk_size: chunk_size,
          status: :processing,
          inserted_at: DateTime.utc_now()
        }

        chunks = create_chunks(job, chunk_size, fps, temp_dir, operation, options)
        {initial_work, remaining} = Enum.split(chunks, length(players))

        active_chunks =
          players
          |> Enum.zip(initial_work)
          |> Enum.into(%{}, fn {player_id, chunk} ->
            Player.process_chunk(player_id, chunk)
            {player_id, chunk}
          end)

        Logger.info(
          "Job #{job.id} (#{operation}): #{length(chunks)} chunks of #{chunk_size} frames " <>
            "across #{length(players)} players"
        )

        new_state = %{
          state
          | job: job,
            chunk_queue: remaining,
            active_chunks: active_chunks,
            completed_chunks: [],
            failed_chunks: [],
            total_chunks: length(chunks),
            temp_dir: temp_dir,
            total_errors: 0
        }

        {:ok, job.id, new_state}
      end
    end
  end

  # `loop` operates on the whole file, so it is always a single chunk.
  defp chunk_size(requested, total_frames, _player_count, "loop") do
    to_int(requested) || total_frames
  end

  defp chunk_size(requested, total_frames, player_count, _op) do
    to_int(requested) || default_chunk_size(total_frames, player_count)
  end

  defp default_chunk_size(total_frames, player_count) do
    max(10, div(total_frames, max(player_count, 1) * 4))
  end

  # Completion / failure

  defp handle_chunk_success(chunk, state, new_active) do
    new_completed = [chunk | state.completed_chunks]
    completed_count = length(new_completed)

    percent =
      if state.total_chunks > 0 do
        Float.round(completed_count / state.total_chunks * 100, 1)
      else
        0.0
      end

    Logger.info(
      "progress #{percent}% (#{completed_count}/#{state.total_chunks}) " <>
        "queue=#{length(state.chunk_queue)} active=#{map_size(new_active)}"
    )

    state = %{
      state
      | active_chunks: new_active,
        completed_chunks: new_completed,
        job: %{state.job | chunks_completed: completed_count}
    }

    {:noreply, finalize_if_done(state)}
  end

  defp handle_chunk_failure(chunk, player_id, error, state, new_active) do
    updated = %{
      chunk
      | retry_count: chunk.retry_count + 1,
        failed_by: [player_id | chunk.failed_by]
    }

    total_errors = state.total_errors + 1

    Logger.warning(
      "chunk #{short(chunk.id)} failed on #{player_id} " <>
        "(retry #{updated.retry_count}): #{inspect(error)}"
    )

    cond do
      updated.retry_count >= @max_retries ->
        Logger.error("chunk #{short(chunk.id)} permanently failed after #{@max_retries} attempts")

        state = %{
          state
          | active_chunks: new_active,
            failed_chunks: [updated | state.failed_chunks],
            total_errors: total_errors
        }

        {:noreply, finalize_if_done(state)}

      total_errors >= @max_total_errors ->
        Logger.error("global error limit reached (#{@max_total_errors}); failing job")

        {:noreply,
         %{
           state
           | active_chunks: new_active,
             total_errors: total_errors,
             chunk_queue: [],
             job: %{state.job | status: :failed}
         }}

      true ->
        # Put the chunk back at the front; the failing player's own prefetch
        # request will pick a *different* chunk because failed_by excludes it.
        {:noreply,
         %{
           state
           | active_chunks: new_active,
             chunk_queue: [updated | state.chunk_queue],
             total_errors: total_errors
         }}
    end
  end

  defp finalize_if_done(%{job: nil} = state), do: state

  defp finalize_if_done(state) do
    done = length(state.completed_chunks) + length(state.failed_chunks)

    cond do
      done < state.total_chunks ->
        state

      state.failed_chunks == [] ->
        %{
          state
          | job: %{
              state.job
              | status: :completed,
                chunks_completed: length(state.completed_chunks)
            }
        }

      true ->
        %{
          state
          | job: %{state.job | status: :failed, chunks_completed: length(state.completed_chunks)}
        }
    end
  end

  # Chunk creation / lookup

  defp find_eligible_chunk(queue, player_id) do
    # Prefer a chunk this player has not failed yet; otherwise fall back to
    # the head of the queue so a chunk can keep accumulating retries and
    # eventually be marked permanently failed instead of deadlocking here.
    case Enum.find_index(queue, fn chunk -> player_id not in chunk.failed_by end) do
      nil ->
        case queue do
          [] -> {nil, queue}
          _ -> List.pop_at(queue, 0)
        end

      index ->
        List.pop_at(queue, index)
    end
  end

  defp create_chunks(job, chunk_size, fps, temp_dir, operation, options) do
    total_frames = job.total_frames
    total_chunks = ceil(total_frames / chunk_size)
    ext = Path.extname(job.output_path)

    for i <- 0..(total_chunks - 1) do
      start_frame = i * chunk_size
      end_frame = min(start_frame + chunk_size - 1, total_frames - 1)
      chunk_out = Path.join(temp_dir, "chunk_#{i}#{ext}")

      Chunk.new(job.id, start_frame, end_frame, job.input_path, chunk_out,
        operation: operation,
        options: options,
        fps: fps
      )
    end
  end

  # Small helpers

  defp short(id), do: String.slice(id, 0..7)

  defp to_int(nil), do: nil
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value),
    do:
      (case Integer.parse(value) do
         {int, _} -> int
         :error -> nil
       end)

  defp to_float(nil), do: nil
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end
end
