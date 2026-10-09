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

# The browser preview suite (browser_preview_test.exs) drives the real
# Chromium through tests/browser/editor_runner.mjs (playwright-core, npm ci).
# A machine without Chromium (or FRAMER_CHROMIUM pointing at one), without
# Node, or without the built editor assets excludes the suite rather than
# failing it: priv/static/assets is gitignored and built by `mix assets.build`,
# and the page cannot connect its LiveView without app.js. CI installs the
# browser harness and builds the assets, so the suite runs there.
chromium_available? =
  try do
    chromium = System.get_env("FRAMER_CHROMIUM") || "/usr/bin/chromium"
    assets = Path.expand("../priv/static/assets", __DIR__)

    # --version doubles as a real-binary check: Ubuntu 24.04's apt
    # chromium-browser is a snap stub that cannot launch in CI.
    node_available? and File.exists?(chromium) and
      match?({_out, 0}, System.cmd(chromium, ["--version"], stderr_to_stdout: true)) and
      File.exists?(Path.join(assets, "js/app.js")) and
      File.exists?(Path.join(assets, "css/app.css"))
  rescue
    _ -> false
  end

unless chromium_available? do
  ExUnit.configure(exclude: [:requires_chromium])
end
