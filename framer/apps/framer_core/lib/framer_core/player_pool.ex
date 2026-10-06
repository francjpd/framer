defmodule FramerCore.PlayerPool do
  @moduledoc """
  Supervises the player processes with a `DynamicSupervisor` so the number of
  workers can genuinely change at runtime.

  The pool is the single source of truth for "which players exist". The
  `Orchestrator` asks the pool for the current player list when a job starts,
  so scaling workers does not leave the orchestrator holding a stale list.

  Local players own a Python `FramerCore.PortWorker`. Remote players are the
  distribution seam: they are backed by a `FramerCore.Dispatch` remote target
  and are configured with `config :framer_core, :remote_players` as a list of
  `{id, {node, worker_ref}}`. No remote players means the system runs entirely
  locally.
  """

  use GenServer
  require Logger

  @dynsup FramerCore.PlayerSupervisor

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the ids of the players currently registered in the pool."
  def players do
    GenServer.call(__MODULE__, :players)
  end

  @doc """
  Replace the current players with a fresh set.

  Call this while the pool is idle (the CLI does this before submitting a job);
  stopping a player abandons any chunk it was working on, which the
  orchestrator would otherwise retry forever.
  """
  def set_worker_count(count) when is_integer(count) and count > 0 do
    GenServer.call(__MODULE__, {:set_worker_count, count})
  end

  @doc "Default number of local players for this host."
  def default_count do
    min(6, max(2, System.schedulers_online() - 2))
  end

  # Server callbacks

  @impl true
  def init(opts) do
    count = opts[:count] || Application.get_env(:framer_core, :worker_count) || default_count()
    remote = opts[:remote_players] || Application.get_env(:framer_core, :remote_players, [])

    {:ok, start_players(%{count: count, remote: remote, players: []})}
  end

  @impl true
  def handle_call(:players, _from, state) do
    {:reply, Enum.map(state.players, &elem(&1, 0)), state}
  end

  def handle_call({:set_worker_count, count}, _from, state) do
    for {_id, pid} <- state.players do
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(@dynsup, pid)
    end

    {:reply, :ok, start_players(%{state | count: count, players: []})}
  end

  defp start_players(state) do
    local = for i <- 1..state.count, do: start_local("player-#{i}")
    remote = for {id, target} <- state.remote, do: start_remote(to_string(id), target)

    Logger.info(
      "FramerCore.PlayerPool started #{length(local)} local and #{length(remote)} remote players"
    )

    %{state | players: local ++ remote}
  end

  defp start_local(id) do
    start_player(id, FramerCore.Player, id: id, backend: :local)
  end

  defp start_remote(id, {node, worker_ref}) do
    target = FramerCore.Dispatch.remote(node, worker_ref)
    start_player(id, FramerCore.Player, id: id, backend: :remote, worker: target)
  end

  defp start_player(id, module, args) do
    spec = %{
      id: {module, id},
      start: {module, :start_link, [args]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(@dynsup, spec) do
      {:ok, pid} -> {id, pid}
      {:error, reason} -> raise "could not start player #{id}: #{inspect(reason)}"
    end
  end
end
