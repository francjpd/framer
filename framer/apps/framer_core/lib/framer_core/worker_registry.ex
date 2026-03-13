defmodule FramerCore.WorkerRegistry do
  @moduledoc """
  Registry for workers - allows looking up workers by ID.
  Uses Elixir's Registry for fast lookups.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Registry, :start_link, [[keys: :unique, name: __MODULE__]]},
      type: :worker
    }
  end
end
