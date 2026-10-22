import Config

# Keep the test worker pool small and deterministic.
config :framer_core, worker_count: 2

# Filesystem-first editor persistence: give the test suite its own projects
# root so `mix test` never reads or writes a developer's real projects.
config :framer_web,
  projects_dir: Path.join(System.tmp_dir!(), "framer_web_projects_test")

# The healing corpus lives in a database of its own, in the temporary
# directory: every `mix test` run gets a fresh one, so the corpus a test
# leaves behind never reaches the next run.
config :framer_web, FramerWeb.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "framer_web_test_#{System.unique_integer([:positive])}.db"
    ),
  # One connection: SQLite writes are serialised anyway, and a second
  # connection opening while the schema is being migrated would only race
  # for the lock.
  pool_size: 1,
  busy_timeout: 5000

# We don't run a server during test. If one is required,
# you can enable the server option below. The browser preview suite
# (browser_preview_test.exs) flips `server` on at runtime and restarts the
# endpoint, so it serves the editor to the real Chromium on this port.
# `check_origin: false` lets that browser's LiveView websocket connect: the
# endpoint url host is "localhost" while the browser origin is 127.0.0.1:4002,
# which the default origin check would reject (test-only configuration).
config :framer_web, FramerWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  secret_key_base: "/iUQ6Ah4UDMhZ3eYkYvluCUyqqAUawO01I/8/N/AUJz6dvCH0yzL+rJfTCuXf2cr",
  server: false

# In test we don't send emails
config :framer_web, FramerWeb.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
