defmodule FramerCore.Supervisor do
  @moduledoc """
  Root supervisor for the FramerCore application.

  The tree is intentionally small:

      FramerCore.Supervisor
        ├── FramerCore.PlayerRegistry     (Registry: player id -> pid)
        ├── FramerCore.PlayerSupervisor   (DynamicSupervisor of players)
        ├── FramerCore.PlayerPool         (owns how many players exist)
        └── FramerCore.Orchestrator       (chunk queue + assignments)
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Update the number of local Python players at runtime.
  """
  def set_worker_count(count) when is_integer(count) and count > 0 do
    FramerCore.PlayerPool.set_worker_count(count)
  end

  @impl true
  def init(_opts) do
    children = [
      FramerCore.PlayerRegistry,
      {DynamicSupervisor, name: FramerCore.PlayerSupervisor, strategy: :one_for_one},
      {FramerCore.PlayerPool, []},
      {FramerCore.Orchestrator, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
