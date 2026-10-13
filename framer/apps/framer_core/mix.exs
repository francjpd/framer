defmodule FramerCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :framer_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Builds the `framer` escript: a standalone binary over the BEAM
      # orchestrator and the Python Port, so the chunked/parallel path is the
      # default way to run an operation. Build it from this app's directory:
      #
      #     cd framer/apps/framer_core && mix escript.build   # -> ./framer
      #
      # Config from config/config.exs (and config/runtime.exs) is baked into the
      # escript, which is why it is built in :dev/:test and never :prod - the
      # prod runtime config demand DATABASE_URL for framer_web, which the CLI
      # does not use. `app: nil` means the command surface starts the runtime
      # itself (FramerCore.ensure_started!/0), so the catalog commands answer
      # without booting a player pool.
      escript: [main_module: FramerCore.CLI, path: "framer", app: nil],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :req],
      mod: {FramerCore.Application, []}
    ]
  end

  # `test/support` holds helpers shared by the suites (test media, decoders).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"},
      {:req, "~> 0.5"}
    ]
  end
end
