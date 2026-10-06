import Config

# Keep the test worker pool small and deterministic.
config :framer_core, worker_count: 2

# Configure your database (commented out: requires PostgreSQL)
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# config :framer_web, FramerWeb.Repo,
#   username: "postgres",
#   password: "postgres",
#   hostname: "localhost",
#   database: "framer_web_test#{System.get_env("MIX_TEST_PARTITION")}",
#   pool: Ecto.Adapters.SQL.Sandbox,
#   pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :framer_web, FramerWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
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
