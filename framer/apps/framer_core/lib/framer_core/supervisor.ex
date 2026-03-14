defmodule FramerCore.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Detect cores and spawn players accordingly
    cpu_cores = System.schedulers_online()
    # Limit to 6 players as requested
    cpu_player_count = min(6, max(2, cpu_cores - 2))
    
    IO.puts("🚀 [Supervisor] System detected with #{cpu_cores} cores. Spawning #{cpu_player_count} CPU players...")

    # We want the string IDs for the Orchestrator to use
    cpu_ids = for i <- 1..cpu_player_count, do: "cpu-#{i}"
    gpu_ids = ["gpu-1"]
    all_player_ids = cpu_ids ++ gpu_ids

    # Create child specs
    cpu_players = for id <- cpu_ids do
      Supervisor.child_spec({FramerCore.Player, [id: id, type: :cpu]}, id: String.to_atom("player_#{id}"))
    end

    gpu_players = [
      Supervisor.child_spec({FramerCore.Player, [id: "gpu-1", type: :gpu]}, id: :player_gpu_1)
    ]

    # ORDER MATTERS: Registry first, then Players, then Orchestrator
    children = [
      FramerCore.PlayerRegistry
    ] ++ cpu_players ++ gpu_players ++ [
      {FramerCore.Orchestrator, [players: all_player_ids]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
