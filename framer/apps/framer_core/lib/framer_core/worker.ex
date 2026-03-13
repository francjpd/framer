defmodule FramerCore.Worker do
  @moduledoc """
  Worker process that handles chunk processing.

  Each worker has its own inbox (message queue) - this is the Actor model.
  The orchestrator sends messages directly to each worker's inbox.
  """

  use GenServer

  alias FramerCore.Job.Chunk

  @prefetch_threshold 0.80

  defstruct [
    :id,
    :status,
    :current_chunk,
    :progress,
    :total_processed
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :idle | :busy,
          current_chunk: Chunk.t() | nil,
          progress: float(),
          total_processed: non_neg_integer()
        }

  # Client API

  def start_link(opts) do
    id = opts[:id] || UUID.uuid4()
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  def via_tuple(id) do
    {:via, Registry, {FramerCore.WorkerRegistry, id}}
  end

  def process_chunk(worker_id, chunk) do
    GenServer.cast(via_tuple(worker_id), {:process_chunk, chunk})
  end

  def get_status(worker_id) do
    GenServer.call(via_tuple(worker_id), :get_status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       id: opts[:id] || UUID.uuid4(),
       status: :idle,
       current_chunk: nil,
       progress: 0.0,
       total_processed: 0
     }}
  end

  @impl true
  def handle_cast({:process_chunk, chunk}, state) do
    # Start processing the chunk
    # In real implementation, this would call Rust/Python
    new_state = %{state | status: :busy, current_chunk: chunk}

    # Simulate starting chunk processing
    # In reality, we'd spawn a task or call the processing pipeline
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:check_prefetch, state) do
    # Check if we're near completion and need more work
    if state.status == :busy && state.progress >= @prefetch_threshold do
      # Send prefetch request to orchestrator
      send(FramerCore.Orchestrator.pid(), {:prefetch_request, state.id})
    end

    {:noreply, state}
  end
end
