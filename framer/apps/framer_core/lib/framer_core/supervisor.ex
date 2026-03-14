defmodule FramerCore.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      FramerCore.PlayerRegistry,
      {FramerCore.Orchestrator, []},
      # Dynamically start players based on system capabilities
      # For now, we'll start a few default ones
      Supervisor.child_spec({FramerCore.Player, [id: "cpu-1", type: :cpu]}, id: :player_cpu_1),
      Supervisor.child_spec({FramerCore.Player, [id: "cpu-2", type: :cpu]}, id: :player_cpu_2),
      Supervisor.child_spec({FramerCore.Player, [id: "gpu-1", type: :gpu]}, id: :player_gpu_1)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
