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
      _ -> false
    end
  rescue
    _ -> false
  end

unless cv2_available? do
  ExUnit.configure(exclude: [:requires_cv2])
end
