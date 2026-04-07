defmodule FramerCore.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Updates the number of active CPU players at runtime.
  """
  def set_worker_count(count) do
    # This is a bit advanced: we tell the supervisor to restart with new specs
    # For a simple PoC, we'll just store the count in a global config and 
    # let the user know they should restart or we can try a more advanced hot-swap.
    # To keep it simple and safe for now, we'll just use the count for the NEXT job
    # or implement a DynamicSupervisor if we want true hot-swapping.
    
    # For now, let's just use Application env to share the desired count.
    Application.put_env(:framer_core, :worker_count, count)
    
    # Trigger a restart of the children with the new count
    Supervisor.terminate_child(__MODULE__, FramerCore.Orchestrator)
    
    # Terminate all existing players
    existing_players = Supervisor.which_children(__MODULE__)
    |> Enum.filter(fn {id, _, _, _} -> 
      id_str = Atom.to_string(id)
      String.starts_with?(id_str, "player_cpu") or id_str == "player_gpu_1"
    end)
    
    for {id, _, _, _} <- existing_players do
      Supervisor.terminate_child(__MODULE__, id)
      Supervisor.delete_child(__MODULE__, id)
    end

    # Now we start the new ones
    init_children(count)
    
    # Give it a moment to register
    Process.sleep(500)
    :ok
  end

  @impl true
  def init(_opts) do
    # Default count
    cpu_cores = System.schedulers_online()
    default_count = min(6, max(2, cpu_cores - 2))
    
    count = Application.get_env(:framer_core, :worker_count, default_count)
    
    # Since init is only called once, we'll split the logic
    # but for the VERY FIRST start, we just proceed.
    children = build_child_specs(count)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp init_children(count) do
    # Dynamically start children after the supervisor is already running
    specs = build_child_specs(count)
    
    # We skip Registry if it's already running
    for spec <- specs do
      case spec do
        %{id: id} -> 
           # If it's Registry or something already there, skip
           if Process.whereis(id) == nil do
             Supervisor.start_child(__MODULE__, spec)
           end
        _ -> 
           Supervisor.start_child(__MODULE__, spec)
      end
    end
  end

  defp build_child_specs(cpu_player_count) do
    IO.puts("🚀 [Supervisor] Spawning #{cpu_player_count} CPU players...")

    cpu_ids = for i <- 1..cpu_player_count, do: "cpu-#{i}"
    gpu_ids = ["gpu-1"]
    all_player_ids = cpu_ids ++ gpu_ids

    cpu_players = for id <- cpu_ids do
      Supervisor.child_spec({FramerCore.Player, [id: id, type: :cpu]}, id: String.to_atom("player_#{id}"))
    end

    gpu_players = [
      Supervisor.child_spec({FramerCore.Player, [id: "gpu-1", type: :gpu]}, id: :player_gpu_1)
    ]

    [
      FramerCore.PlayerRegistry
    ] ++ cpu_players ++ gpu_players ++ [
      {FramerCore.Orchestrator, [players: all_player_ids]}
    ]
  end
end
