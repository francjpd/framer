defmodule FramerCore.Orchestrator do
  @moduledoc """
  Orchestrator that manages workers and assigns chunks.

  This is the single source of truth - workers request chunks,
  orchestrator assigns them. No race conditions because only
  the orchestrator can assign chunks.
  """

  use GenServer

  alias FramerCore.Job
  alias FramerCore.Job.Chunk
  alias FramerCore.Worker

  @chunk_size 20

  defstruct [
    :job,
    :chunk_queue,
    :workers,
    :total_chunks
  ]

  @type t :: %__MODULE__{
          job: Job.t() | nil,
          chunk_queue: [Chunk.t()],
          workers: [String.t()],
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
    {:ok,
     %__MODULE__{
       job: nil,
       chunk_queue: [],
       workers: [],
       total_chunks: 0
     }}
  end

  @impl true
  def handle_call({:submit_job, input_path, output_path, opts}, _from, state) do
    # Get video info - in real impl, call Rust NIF
    total_frames = opts[:total_frames] || 1000

    # Create job
    job = Job.new(input_path, output_path, total_frames: total_frames)

    # Create chunks
    chunks = create_chunks(job.id, total_frames, @chunk_size)

    # Assign initial chunks to available workers
    {assigned_chunks, remaining_chunks} =
      Enum.split(chunks, min(length(chunks), length(state.workers)))

    for chunk <- assigned_chunks do
      # Find an available worker and assign the chunk
      worker_id = Enum.random(state.workers)
      Worker.process_chunk(worker_id, chunk)
    end

    {:reply, {:ok, job.id},
     %{
       state
       | job: %{job | total_frames: total_frames, status: :processing},
         chunk_queue: remaining_chunks,
         total_chunks: length(chunks)
     }}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:prefetch_request, worker_id}, state) do
    # Worker is asking for more work
    case state.chunk_queue do
      [] ->
        # No more chunks available
        {:noreply, state}

      [chunk | remaining_chunks] ->
        # Assign next chunk to this worker
        Worker.process_chunk(worker_id, chunk)
        {:noreply, %{state | chunk_queue: remaining_chunks}}
    end
  end

  @impl true
  def handle_info({:chunk_complete, _chunk_id, _result}, state) do
    # Chunk processing completed
    new_completed = (state.job.chunks_completed || 0) + 1

    if new_completed >= state.total_chunks do
      # Job complete!
      {:noreply,
       %{state | job: %{state.job | status: :completed, chunks_completed: new_completed}}}
    else
      {:noreply, %{state | job: %{state.job | chunks_completed: new_completed}}}
    end
  end

  # Private functions

  defp create_chunks(job_id, total_frames, chunk_size) do
    total_chunks = ceil(total_frames / chunk_size)

    for i <- 0..(total_chunks - 1) do
      start_frame = i * chunk_size
      end_frame = min(start_frame + chunk_size - 1, total_frames - 1)
      Chunk.new(job_id, start_frame, end_frame)
    end
  end
end
