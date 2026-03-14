defmodule FramerCore.PlayerRegistry do
  @moduledoc """
  Registry for players - allows looking up players by ID.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Registry, :start_link, [[keys: :unique, name: __MODULE__]]},
      type: :worker
    }
  end
end
