ExUnit.start()

# The end-to-end Port tests drive OpenCV through the Python worker. If the
# environment has not been prepared (no `.venv` / `FRAMER_PYTHON`, or a system
# python without cv2), exclude them rather than failing the whole suite; the
# setup steps are documented in docs/elixir-python-ports.md.
cv2_available? =
  try do
    python = FramerCore.PortWorker.python_executable()

    case System.cmd(python, ["-c", "import cv2"], stderr_to_stdout: true) do
      {_out, 0} -> true
      {_out, _status} -> false
    end
  rescue
    _ -> false
  end

unless cv2_available? do
  ExUnit.configure(exclude: [:requires_cv2])
end

# The catalog suite compares the catalog against the operations the Python Port
# worker actually registers, so it needs an interpreter that can import
# `framer_worker.py` (no cv2 required).
worker_import_available? =
  try do
    worker = Application.get_env(:framer_core, :python_worker)
    root = worker |> to_string() |> Path.dirname()

    script = """
    import sys
    sys.path.insert(0, #{inspect(root)})
    import framer_worker
    """

    case System.cmd(FramerCore.PortWorker.python_executable(), ["-c", script],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      {_out, _status} -> false
    end
  rescue
    _ -> false
  end

unless worker_import_available? do
  ExUnit.configure(exclude: [:requires_python])
end
