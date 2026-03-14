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
    :total_chunks
  ]

  @type t :: %__MODULE__{
          job: Job.t() | nil,
          chunk_queue: [Chunk.t()],
          active_chunks: %{String.t() => Chunk.t()},
          completed_chunks: [Chunk.t()],
          players: [String.t()],
          total_chunks: non_neg_integer()
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
       total_chunks: 0
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

    job = %Job{
      id: UUID.uuid4(),
      input_path: input_path,
      output_path: output_path,
      total_frames: total_frames,
      chunks_completed: 0,
      status: :processing
    }

    chunks = create_chunks(job, chunk_size, fps)

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
         total_chunks: length(chunks)
     }}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    sorted_completed = Enum.sort_by(state.completed_chunks, &(&1.start_frame))
    {:reply, %{state | completed_chunks: sorted_completed}, state}
  end

  @impl true
  def handle_info({:prefetch_request, player_id}, state) do
    case state.chunk_queue do
      [] ->
        {:noreply, state}

      [chunk | rest] ->
        Player.process_chunk(player_id, chunk)
        new_active = Map.put(state.active_chunks, player_id, chunk)
        {:noreply, %{state | chunk_queue: rest, active_chunks: new_active}}
    end
  end

  @impl true
  def handle_info({:chunk_finished, player_id, chunk_id, result}, state) do
    {chunk, new_active} = Map.pop(state.active_chunks, player_id)
    
    if chunk && chunk.id == chunk_id do
      case result do
        :ok ->
          handle_chunk_success(chunk, state, new_active)

        {:ok, _path} ->
          handle_chunk_success(chunk, state, new_active)

        error ->
          IO.puts("⚠️ [Orchestrator] Chunk #{chunk_id} failed with #{inspect(error)}. Re-queueing to the back...")
          # Re-queue the failed chunk to the back of the queue
          new_queue = state.chunk_queue ++ [chunk]
          
          # Proactively try to assign work since a player just became available
          # BUT wait, the prefetch_request is coming next, so it should be fine.
          # The real issue is if the queue was empty and prefetch arrived BEFORE the re-queue.
          # To be safe, we can manually trigger a prefetch for the player that just finished.
          
          send(self(), {:prefetch_request, player_id})
          {:noreply, %{state | active_chunks: new_active, chunk_queue: new_queue}}
      end
    else
      # If chunk mismatch, just pop from active and don't re-queue (someone else might have it)
      {:noreply, %{state | active_chunks: new_active}}
    end
  end

  # Private functions

  defp handle_chunk_success(chunk, state, new_active) do
    new_completed = [chunk | state.completed_chunks]
    completed_count = length(new_completed)
    
    percent = (completed_count / state.total_chunks * 100) |> Float.round(1)
    IO.puts("📊 [Orchestrator] Overall progress: #{percent}% (#{completed_count}/#{state.total_chunks} chunks)")

    new_job_status = if completed_count >= state.total_chunks, do: :completed, else: :processing
    
    {:noreply, %{state | 
      active_chunks: new_active, 
      completed_chunks: new_completed,
      job: %{state.job | status: new_job_status, chunks_completed: completed_count}
    }}
  end

  defp create_chunks(job, chunk_size, fps) do
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
        status: :pending
      }
    end
  end
end
