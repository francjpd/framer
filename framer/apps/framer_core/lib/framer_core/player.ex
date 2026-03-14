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
    :current_task_ref,
    :progress,
    :total_processed
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :idle | :busy,
          type: :cpu | :gpu,
          current_chunk: Chunk.t() | nil,
          current_task_ref: reference() | nil,
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
       current_task_ref: nil,
       progress: 0.0,
       total_processed: 0
     }}
  end

  @impl true
  def handle_cast({:process_chunk, chunk}, state) do
    # Log starting work
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts("🎬 [#{timestamp}] [Player #{state.type |> Atom.to_string() |> String.upcase()}-#{state.id |> String.slice(0..7)}] BUSY: Processing chunk #{chunk.id |> String.slice(0..7)} (frames #{chunk.start_frame}-#{chunk.end_frame})")

    task = Task.async(fn ->
      hwaccel = if state.type == :gpu, do: "vaapi", else: nil
      
      # For demo purposes/testing if NIF is not loaded, we wrap it
      try do
        FramerCore.Rust.process_chunk(chunk.input_path, chunk.output_path, chunk.start_frame, chunk.end_frame, chunk.fps || 30.0, hwaccel)
      rescue
        e -> {:error, "NIF Crash: #{inspect(e)}"}
      catch
        kind, reason -> {:error, "NIF Crash: #{inspect(kind)} #{inspect(reason)}"}
      end
    end)

    {:noreply, %{state | status: :busy, current_chunk: chunk, current_task_ref: task.ref}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  # Handle task completion
  @impl true
  def handle_info({ref, result}, %{current_task_ref: ref} = state) do
    # Flush the DOWN message
    Process.demonitor(ref, [:flush])
    
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    chunk_id = state.current_chunk.id

    case result do
      {:error, reason} when state.type == :gpu ->
        IO.puts("⚠️ [#{timestamp}] [Player GPU-#{state.id |> String.slice(0..7)}] GPU FAILURE: #{inspect(reason)}. Falling back to CPU...")
        
        # Retry on CPU immediately in a task
        task = Task.async(fn ->
            FramerCore.Rust.process_chunk(state.current_chunk.input_path, state.current_chunk.output_path, state.current_chunk.start_frame, state.current_chunk.end_frame, state.current_chunk.fps || 30.0, nil)
        end)
        {:noreply, %{state | current_task_ref: task.ref}}

      _ ->
        status_label = if result == :ok || match?({:ok, _}, result), do: "SUCCESS", else: "FAILED"
        IO.puts("✅ [#{timestamp}] [Player #{state.type |> Atom.to_string() |> String.upcase()}-#{state.id |> String.slice(0..7)}] IDLE: #{status_label} chunk #{chunk_id |> String.slice(0..7)}.")
        
        # Notify Orchestrator of completion
        send(FramerCore.Orchestrator.pid(), {:chunk_finished, state.id, chunk_id, result})
        
        # Ask for more work
        send(FramerCore.Orchestrator.pid(), {:prefetch_request, state.id})
        
        {:noreply, %{state | status: :idle, current_chunk: nil, current_task_ref: nil, total_processed: state.total_processed + 1}}
    end
  end

  # Handle task failure
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task_ref: ref} = state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    chunk_id = state.current_chunk.id
    
    IO.puts("🚨 [#{timestamp}] [Player #{state.type |> Atom.to_string() |> String.upcase()}-#{state.id |> String.slice(0..7)}] CRASHED while processing chunk #{chunk_id |> String.slice(0..7)}: #{inspect(reason)}")
    
    # Notify Orchestrator of failure
    send(FramerCore.Orchestrator.pid(), {:chunk_finished, state.id, chunk_id, {:error, :crashed}})
    
    # Ready for more work despite failure
    send(FramerCore.Orchestrator.pid(), {:prefetch_request, state.id})
    
    {:noreply, %{state | status: :idle, current_chunk: nil, current_task_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
