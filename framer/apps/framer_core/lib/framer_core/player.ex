defmodule FramerCore.Player do
  @moduledoc """
  A player executes one chunk at a time through the Port contract.

  Each player owns a persistent `FramerCore.PortWorker` (its Python process)
  and runs the blocking request in a `Task` so its own mailbox stays
  responsive. The worker is reused for every chunk, so a job with a thousand
  chunks still uses one Python process per player, not one per frame.
  """

  use GenServer
  require Logger

  alias FramerCore.Dispatch
  alias FramerCore.Job.Chunk

  defstruct [
    :id,
    :backend,
    :worker,
    :status,
    :current_chunk,
    :current_task_ref,
    :total_processed
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          backend: :local | :remote,
          worker: term(),
          status: :idle | :busy,
          current_chunk: Chunk.t() | nil,
          current_task_ref: reference() | nil,
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

  @doc """
  Run a job's preparation request.

  The preparation is the work every chunk of the job needs before any chunk
  can run - the export's patch, for instance.  It is not a chunk: it has no
  frame range and it is not merged into the output, so it is reported back
  under its own name.
  """
  def prepare(player_id, request) do
    GenServer.cast(via_tuple(player_id), {:prepare, request})
  end

  def get_status(player_id) do
    GenServer.call(via_tuple(player_id), :get_status)
  end

  def stop(player_id) do
    GenServer.stop(via_tuple(player_id))
  end

  # Server callbacks

  @impl true
  def init(opts) do
    id = opts[:id] || UUID.uuid4()
    backend = opts[:backend] || :local

    worker =
      case backend do
        :local ->
          {:ok, pid} = FramerCore.PortWorker.start_link([])
          pid

        :remote ->
          opts[:worker] || raise "remote player requires a :worker target"
      end

    {:ok,
     %__MODULE__{
       id: id,
       backend: backend,
       worker: worker,
       status: :idle,
       current_chunk: nil,
       current_task_ref: nil,
       total_processed: 0
     }}
  end

  @impl true
  def handle_cast({:process_chunk, chunk}, state) do
    target = target(state)

    task =
      Task.async(fn ->
        Dispatch.execute(target, Chunk.to_request(chunk))
      end)

    {:noreply, %{state | status: :busy, current_chunk: chunk, current_task_ref: task.ref}}
  end

  @impl true
  def handle_cast({:prepare, request}, state) do
    target = target(state)

    task =
      Task.async(fn ->
        Dispatch.execute(target, request)
      end)

    {:noreply, %{state | status: :busy, current_chunk: nil, current_task_ref: task.ref}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({ref, result}, %{current_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_work(state, result)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task_ref: ref} = state) do
    {:noreply, finish_work(state, {:error, {:task_down, reason}})}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp target(%__MODULE__{backend: :local, worker: worker}), do: Dispatch.local(worker)
  defp target(%__MODULE__{backend: :remote, worker: worker}), do: worker

  # The work that finished was either a chunk - which the orchestrator counts
  # and retries - or the job's preparation, which the orchestrator waits for
  # before it dispatches any chunk.
  defp finish_work(state, result) do
    case state.current_chunk do
      nil ->
        notify({:prepare_finished, state.id, result})

      chunk ->
        notify({:chunk_finished, state.id, chunk.id, result})
        notify({:prefetch_request, state.id})
    end

    %{
      state
      | status: :idle,
        current_chunk: nil,
        current_task_ref: nil,
        total_processed: state.total_processed + 1
    }
  end

  defp notify(message) do
    case FramerCore.Orchestrator.pid() do
      nil -> :ok
      pid -> send(pid, message)
    end
  end
end
