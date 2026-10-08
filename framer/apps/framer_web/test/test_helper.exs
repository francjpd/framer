ExUnit.start()
# Ecto.Adapters.SQL.Sandbox.mode(FramerWeb.Repo, :manual)

# The editor's end-to-end tests drive the engine through the Python Port
# worker. If the environment has not been prepared (no `.venv` / `FRAMER_PYTHON`,
# or a system python without cv2), exclude them rather than failing the suite.
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

node_available? = System.find_executable("node") != nil

unless node_available? do
  ExUnit.configure(exclude: [:requires_node])
end
