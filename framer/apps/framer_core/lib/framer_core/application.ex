defmodule FramerCore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    FramerCore.Supervisor.start_link(name: FramerCore.Supervisor)
  end
end
