defmodule FramerCore.Orchestrator do
  @moduledoc """
  Orchestrator that manages players and assigns chunks.
  """

  use GenServer

  alias FramerCore.Job
  alias FramerCore.Job.Chunk
  alias FramerCore.Player

  defstruct [
    :job,
    :chunk_queue,
    :active_chunks,
    :completed_chunks,
    :players,
    :total_chunks,
    total_errors: 0
  ]

  @type t :: %__MODULE__{
          job: Job.t() | nil,
          chunk_queue: [Chunk.t()],
          active_chunks: %{String.t() => Chunk.t()},
          completed_chunks: [Chunk.t()],
          players: [String.t()],
          total_chunks: non_neg_integer(),
          total_errors: non_neg_integer()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def pid do
    Process.whereis(__MODULE__)
  end

  def submit_job(input_path, output_path, opts \\ []) do
    GenServer.call(__MODULE__, {:submit_job, input_path, output_path, opts})
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    players = ["cpu-1", "cpu-2", "gpu-1"]
    
    {:ok,
     %__MODULE__{
       job: nil,
       chunk_queue: [],
       active_chunks: %{},
       completed_chunks: [],
       players: players,
       total_chunks: 0,
       total_errors: 0
     }}
  end

  @impl true
  def handle_call({:submit_job, input_path, output_path, opts}, _from, state) do
    total_frames = opts[:total_frames]
    total_frames = if is_binary(total_frames), do: String.to_integer(total_frames), else: total_frames
    
    chunk_size = opts[:chunk_size] || 50
    chunk_size = if is_binary(chunk_size), do: String.to_integer(chunk_size), else: chunk_size
    
    fps = opts[:fps] || 30.0
    fps = cond do
      is_binary(fps) -> String.to_float(fps)
      is_number(fps) -> fps * 1.0
      true -> 30.0
    end

    target_fps = opts[:target_fps]
    target_fps = if is_binary(target_fps), do: String.to_integer(target_fps), else: target_fps

    job = %Job{
      id: UUID.uuid4(),
      input_path: input_path,
      output_path: output_path,
      total_frames: total_frames,
      chunks_completed: 0,
      status: :processing
    }

    chunks = create_chunks(job, chunk_size, fps, target_fps)

    {initial_work, remaining} = Enum.split(chunks, length(state.players))
    
    # Track active chunks by player_id
    active_chunks = 
      Enum.zip(state.players, initial_work)
      |> Enum.into(%{}, fn {player_id, chunk} -> 
        Player.process_chunk(player_id, chunk)
        {player_id, chunk}
      end)

    {:reply, {:ok, job.id},
     %{
       state
       | job: job,
         chunk_queue: remaining,
         active_chunks: active_chunks,
         completed_chunks: [],
         total_chunks: length(chunks),
         total_errors: 0
     }}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    sorted_completed = Enum.sort_by(state.completed_chunks, &(&1.start_frame))
    {:reply, %{state | completed_chunks: sorted_completed}, state}
  end

  @impl true
  def handle_info({:prefetch_request, player_id}, state) do
    # Only assign work if the job is still processing
    if state.job && state.job.status == :processing do
        # Find a player's type (cpu/gpu)
        player_status = Player.get_status(player_id)
        player_type = player_status.type

        # Find eligible chunk: 
        # 1. Not failed by this specific player
        # 2. If it failed on GPU before, prefer CPU now
        {chunk, rest} = find_eligible_chunk(state.chunk_queue, player_id, player_type)

        case chunk do
          nil ->
            {:noreply, state}

          chunk ->
            Player.process_chunk(player_id, chunk)
            new_active = Map.put(state.active_chunks, player_id, chunk)
            {:noreply, %{state | chunk_queue: rest, active_chunks: new_active}}
        end
    else
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:chunk_finished, player_id, chunk_id, result}, state) do
    {chunk, new_active} = Map.pop(state.active_chunks, player_id)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    
    if chunk && chunk.id == chunk_id do
      case result do
        :ok ->
          handle_chunk_success(chunk, state, new_active)

        {:ok, _path} ->
          handle_chunk_success(chunk, state, new_active)

        _error ->
          # Increment retry count and add to blacklist
          updated_chunk = %{chunk | 
            retry_count: chunk.retry_count + 1,
            failed_by: [player_id | chunk.failed_by]
          }
          
          new_total_errors = state.total_errors + 1
          IO.puts("⚠️ [#{timestamp}] [Orchestrator] FAILURE: Chunk #{chunk_id |> String.slice(0..7)} failed on #{player_id} (Retry #{updated_chunk.retry_count}).")
          
          cond do
            updated_chunk.retry_count >= 3 ->
                IO.puts("🚨 [#{timestamp}] [Orchestrator] SKIPPING chunk #{chunk_id |> String.slice(0..7)}: Too many retries.")
                # We skip the chunk instead of aborting the whole job now
                handle_chunk_success(updated_chunk, %{state | total_errors: new_total_errors}, new_active)

            new_total_errors >= 20 ->
                IO.puts("🚨 [#{timestamp}] [Orchestrator] CRITICAL: Global error limit reached (20). ABORTING JOB.")
                {:noreply, %{state | 
                    active_chunks: new_active, 
                    total_errors: new_total_errors,
                    chunk_queue: [],
                    job: %{state.job | status: :failed}
                }}

            true ->
                # Re-queue the failed chunk to the FRONT of the queue to try another player immediately
                new_queue = [updated_chunk | state.chunk_queue]
                send(self(), {:prefetch_request, player_id})
                {:noreply, %{state | active_chunks: new_active, chunk_queue: new_queue, total_errors: new_total_errors}}
          end
      end
    else
      # If chunk mismatch, just pop from active and don't re-queue (someone else might have it)
      {:noreply, %{state | active_chunks: new_active}}
    end
  end

  # Private functions

  defp find_eligible_chunk(queue, player_id, player_type) do
    # Find the first chunk that wasn't failed by this player
    # And if this is a GPU player, avoid chunks that already failed on GPU once
    index = Enum.find_index(queue, fn chunk ->
        not (player_id in chunk.failed_by) and not (player_type == :gpu and chunk.retry_count > 0)
    end)

    if index do
        {chunk, rest} = List.pop_at(queue, index)
        {chunk, rest}
    else
        # If no "perfect" chunk, just take the first one if we haven't failed it ourselves
        fallback_index = Enum.find_index(queue, fn chunk -> not (player_id in chunk.failed_by) end)
        if fallback_index do
            List.pop_at(queue, fallback_index)
        else
            {nil, queue}
        end
    end
  end

  defp handle_chunk_success(chunk, state, new_active) do
    new_completed = [chunk | state.completed_chunks]
    completed_count = length(new_completed)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    
    percent = (completed_count / state.total_chunks * 100) |> Float.round(1)
    IO.puts("📊 [#{timestamp}] [Orchestrator] PROGRESS: #{percent}% (#{completed_count}/#{state.total_chunks} chunks). Queue size: #{length(state.chunk_queue)}")

    new_job_status = if completed_count >= state.total_chunks, do: :completed, else: :processing
    
    {:noreply, %{state | 
      active_chunks: new_active, 
      completed_chunks: new_completed,
      job: %{state.job | status: new_job_status, chunks_completed: completed_count}
    }}
  end

  defp create_chunks(job, chunk_size, fps, target_fps) do
    total_frames = job.total_frames
    total_chunks = ceil(total_frames / chunk_size)

    for i <- 0..(total_chunks - 1) do
      start_frame = i * chunk_size
      end_frame = min(start_frame + chunk_size - 1, total_frames - 1)
      
      chunk_out = Path.join(Path.dirname(job.output_path), "chunk_#{i}_#{Path.basename(job.output_path)}")
      
      %Chunk{
        id: UUID.uuid4(),
        job_id: job.id,
        start_frame: start_frame,
        end_frame: end_frame,
        input_path: job.input_path,
        output_path: chunk_out,
        fps: fps,
        target_fps: target_fps,
        status: :pending
      }
    end
  end
end
