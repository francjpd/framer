defmodule FramerCore.PortWorker do
  @moduledoc """
  Owns one long-lived Python worker process and speaks a small reusable Port
  protocol with it.

  ## The Port contract

  The BEAM **never** passes pixel data. A request is a map containing:

    * `"op"`          - operation name (`remove-bg`, `fps-boost`, `loop`, `merge`, `info`)
    * `"input"`       - absolute path to the source file (or `nil` for `merge`)
    * `"output"`      - absolute path the worker must write
    * `"start_frame"` - inclusive first frame of the chunk
    * `"end_frame"`   - inclusive last frame of the chunk
    * `"fps"`         - source frame rate
    * `"options"`     - operation specific options as a JSON object

  The Python side reads its input chunk, writes its output chunk and replies
  with `{"id": ..., "status": "ok", ...}` or `{"id": ..., "status": "error",
  "error": ...}`. Framing is a 4 byte big-endian length prefix followed by a
  UTF-8 JSON payload (`packet: 4`).

  A worker process serves requests sequentially, so one `PortWorker` maps to
  one `Player` and is reused for every chunk it handles rather than spawning a
  process per frame.
  """
  use GenServer
  require Logger

  @default_timeout 600_000

  defstruct [:port, :pending]

  @type t :: %__MODULE__{port: port() | nil, pending: %{String.t() => GenServer.from()}}

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run one request and block until the worker replies."
  @spec run(pid() | GenServer.server(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def run(pid, request, timeout \\ @default_timeout) do
    try do
      GenServer.call(pid, {:run, normalize(request)}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, {:port_worker_exit, reason}}
    end
  end

  @doc """
  Start a throwaway worker, run a single request and stop it.

  Used for one-off operations such as `merge` or `info` that do not belong
  to the chunked job pipeline.
  """
  def run_once(request, timeout \\ @default_timeout) do
    {:ok, pid} = start_link()

    try do
      run(pid, request, timeout)
    after
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    python = opts[:python] || python_executable()
    worker = opts[:worker] || Application.get_env(:framer_core, :python_worker)

    if is_nil(worker) do
      raise "FramerCore.PortWorker: :python_worker is not configured"
    end

    worker = Path.expand(worker)

    unless File.exists?(worker) do
      raise "FramerCore.PortWorker: python worker script not found at #{worker}"
    end

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        packet: 4,
        args: [worker]
      ])

    {:ok, %__MODULE__{port: port, pending: %{}}}
  end

  @impl true
  def handle_call({:run, request}, from, %{port: port} = state) when is_port(port) do
    id = request["id"] || UUID.uuid4()
    request = Map.put(request, "id", id)
    Port.command(port, Jason.encode!(request))
    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  end

  def handle_call({:run, _request}, _from, state) do
    {:reply, {:error, :worker_down}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, %{"id" => id} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            {:noreply, state}

          {from, pending} ->
            GenServer.reply(from, to_result(response))
            {:noreply, %{state | pending: pending}}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, {:worker_exit, status}})
    end

    Logger.error("FramerCore Python worker exited with status #{status}")
    {:stop, {:worker_exit, status}, %{state | pending: %{}, port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp to_result(%{"status" => "ok"} = response), do: {:ok, response}
  defp to_result(%{"status" => "error", "error" => error}), do: {:error, error}
  defp to_result(other), do: {:error, {:bad_response, other}}

  defp normalize(request) do
    request
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp python_executable do
    configured = Application.get_env(:framer_core, :python_executable)
    resolve_executable(configured || default_python())
  end

  defp resolve_executable(candidate) do
    resolved =
      cond do
        Path.type(candidate) == :absolute -> candidate
        true -> System.find_executable(candidate) || candidate
      end

    unless File.exists?(resolved) do
      raise "FramerCore.PortWorker: python executable not found: #{inspect(candidate)}"
    end

    resolved
  end

  defp default_python do
    root = Application.get_env(:framer_core, :project_root)
    venv = root && Path.join(root, ".venv/bin/python")

    if venv && File.exists?(venv) do
      venv
    else
      "python3"
    end
  end
end
