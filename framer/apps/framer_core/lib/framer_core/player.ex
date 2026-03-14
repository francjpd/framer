defmodule FramerCore.Player do
  @moduledoc """
  Player process that handles chunk processing.
  """

  use GenServer
  require Logger

  alias FramerCore.Job.Chunk

  defstruct [
    :id,
    :status,
    :type,
    :current_chunk,
    :progress,
    :total_processed
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :idle | :busy,
          type: :cpu | :gpu,
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
    {:via, Registry, {FramerCore.PlayerRegistry, id}}
  end

  def process_chunk(player_id, chunk) do
    GenServer.cast(via_tuple(player_id), {:process_chunk, chunk})
  end

  def get_status(player_id) do
    GenServer.call(via_tuple(player_id), :get_status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       id: opts[:id] || UUID.uuid4(),
       type: opts[:type] || :cpu,
       status: :idle,
       current_chunk: nil,
       progress: 0.0,
       total_processed: 0
     }}
  end

  @impl true
  def handle_cast({:process_chunk, chunk}, state) do
    # Log starting work
    IO.puts("🎬 [Player #{state.type |> Atom.to_string() |> String.upcase()}-#{state.id |> String.slice(0..7)}] Starting chunk: frames #{chunk.start_frame}-#{chunk.end_frame}")

    # Capture self() for the task
    player_pid = self()

    Task.start(fn ->
      hwaccel = if state.type == :gpu, do: "auto", else: nil
      
      result = FramerCore.Rust.process_chunk(chunk.input_path, chunk.output_path, chunk.start_frame, chunk.end_frame, chunk.fps || 30.0, hwaccel)
      
      case result do
        {:error, _} when state.type == :gpu ->
          IO.puts("⚠️ [Player GPU-#{state.id |> String.slice(0..7)}] GPU failed, falling back to CPU...")
          retry_result = FramerCore.Rust.process_chunk(chunk.input_path, chunk.output_path, chunk.start_frame, chunk.end_frame, chunk.fps || 30.0, nil)
          send(player_pid, {:task_finished, chunk.id, retry_result})
        _ ->
          send(player_pid, {:task_finished, chunk.id, result})
      end
    end)

    {:noreply, %{state | status: :busy, current_chunk: chunk}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:task_finished, chunk_id, result}, state) do
    if state.current_chunk && state.current_chunk.id == chunk_id do
        status_label = if result == :ok || match?({:ok, _}, result), do: "Finished", else: "FAILED"
        IO.puts("✅ [Player #{state.type |> Atom.to_string() |> String.upcase()}-#{state.id |> String.slice(0..7)}] #{status_label} chunk.")
        
        # Notify Orchestrator of completion
        send(FramerCore.Orchestrator.pid(), {:chunk_finished, state.id, chunk_id, result})
        
        # Ask for more work
        send(FramerCore.Orchestrator.pid(), {:prefetch_request, state.id})
        
        {:noreply, %{state | status: :idle, current_chunk: nil, total_processed: state.total_processed + 1}}
    else
        {:noreply, state}
    end
  end
end
