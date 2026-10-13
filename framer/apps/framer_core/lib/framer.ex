defmodule FramerCore do
  @moduledoc """
  Documentation for `FramerCore`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> FramerCore.hello()
      :world

  """
  def hello do
    :world
  end

  @doc """
  Start the orchestration runtime if it is not running yet.

  The escript is configured with `app: nil`, so nothing is started for a
  command that does not need it: `framer list` and `framer describe` answer
  from the catalog in memory and must not boot a player pool - four Python
  worker processes and a second of startup - just to enumerate what framer can
  do. Every command that touches the orchestrator, the Port or the host API
  calls this first. It is idempotent.
  """
  @spec ensure_started!() :: :ok
  def ensure_started! do
    case Application.ensure_all_started(:framer_core) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        raise "could not start the FramerCore runtime: #{inspect(reason)}"
    end
  end
end
