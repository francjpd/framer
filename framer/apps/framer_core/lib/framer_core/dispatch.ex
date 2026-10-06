defmodule FramerCore.Dispatch do
  @moduledoc """
  Execution seam for a chunk.

  A *worker target* describes where a request should run:

      %{kind: :local, worker: port_worker_pid}
      %{kind: :remote, node: :"worker@host", worker: worker_ref}

  Locally the request is sent to the `FramerCore.PortWorker` that owns the
  Python process. The remote branch is the documented seam for distributing
  chunks across machines: a remote node runs the same OTP release, exposes a
  `FramerCore.PortWorker` (registered by name in its `FramerCore.PlayerPool`)
  and the orchestrator simply points a player at `{:remote, node}` instead of
  `:local`.

  Nothing else in the orchestrator changes when remote nodes are added: a
  chunk already carries operation, paths, range and options, and the BEAM
  still never touches pixel data. The system runs entirely without a cluster
  because the local branch is the default.

  This is intentionally a plain function seam rather than an abstraction layer:
  there is one code path today and one clearly-marked extension point.
  """

  @default_timeout 600_000

  @doc "Execute a request on the given worker target."
  @spec execute(map() | pid(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def execute(target, request, timeout \\ @default_timeout)

  def execute(%{kind: :local, worker: worker}, request, timeout) do
    FramerCore.PortWorker.run(worker, request, timeout)
  end

  def execute(%{kind: :remote, node: node, worker: worker}, request, timeout) do
    try do
      :erpc.call(
        node,
        FramerCore.PortWorker,
        :run,
        [worker, request, timeout],
        timeout + 5_000
      )
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  # Convenience: allow a bare pid to mean "local worker".
  def execute(pid, request, timeout) when is_pid(pid) do
    FramerCore.PortWorker.run(pid, request, timeout)
  end

  @doc """
  Build a local worker target from a `FramerCore.PortWorker` pid.
  """
  def local(port_worker_pid), do: %{kind: :local, worker: port_worker_pid}

  @doc """
  Build a remote worker target.

  `worker_ref` is resolved on `node` by `FramerCore.PortWorker.run/3`; use a
  registered name (for example `{:global, {:player, "player-1"}}`) rather than
  a raw pid so the target survives worker restarts on the remote node.
  """
  def remote(node, worker_ref), do: %{kind: :remote, node: node, worker: worker_ref}
end
