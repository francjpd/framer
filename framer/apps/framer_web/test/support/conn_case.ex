defmodule FramerWebWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FramerWebWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FramerWebWeb.Endpoint

      use FramerWebWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FramerWebWeb.ConnCase
    end
  end

  setup tags do
    FramerWeb.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Leave the orchestrator idle, so the next test has a clean worker.

  A test that leaves a job processing would make the next test's submission
  fail with `job_in_progress`, so the helper waits for the job to reach a
  terminal state.  The orchestrator itself is never stopped: the editor of the
  test that just finished is still polling it, and an orchestrator that
  disappears takes that editor down with it.
  """
  def await_idle_orchestrator(attempts \\ 300) do
    state = FramerCore.Orchestrator.get_status()

    cond do
      is_nil(state.job) ->
        :ok

      state.job.status in [:completed, :failed] ->
        :ok

      attempts <= 0 ->
        :ok

      true ->
        Process.sleep(100)
        await_idle_orchestrator(attempts - 1)
    end
  end

  @doc """
  Wait for the orchestrator's job to reach `status` and return its state.

  The state carries the job's own error, which is what a failed job says
  about itself.
  """
  def await_job_status(status, attempts \\ 100) do
    state = FramerCore.Orchestrator.get_status()

    cond do
      state.job && state.job.status == status ->
        state

      attempts <= 0 ->
        state

      true ->
        Process.sleep(100)
        await_job_status(status, attempts - 1)
    end
  end
end
