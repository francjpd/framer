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
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      rustler_crates: rustler_crates()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FramerCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.35"},
      {:uuid, "~> 1.1"}
    ]
  end

  defp rustler_crates do
    [
      {:framer_rust, path: "native/framer_rust", runtime: nil}
    ]
  end
end
