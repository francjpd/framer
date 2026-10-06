defmodule Mix.Tasks.Framer.Demo do
  @moduledoc """
  Run a video processing job through the Port pipeline so the players can be
  seen working.

  ## Usage

      mix framer.demo <input> <output> [--operation remove-bg] [--workers 4]

  The operation defaults to `fps-boost`; any operation the
  `FramerCore.CLI` understands can be requested.
  """
  use Mix.Task

  @shortdoc "Runs a demo video processing job through the Python Port pipeline"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [operation: :string, workers: :integer, to: :integer]
      )

    case positional do
      [input, output] ->
        operation = opts[:operation] || "fps-boost"

        if workers = opts[:workers] do
          FramerCore.Supervisor.set_worker_count(workers)
        end

        cli_args =
          case operation do
            "fps-boost" -> ["fps-boost", input, output, "--to", to_string(opts[:to] || 60)]
            "remove-bg" -> ["remove-bg", input, output]
            other -> [other, input, output]
          end

        IO.puts("\n🚀 [Demo] #{operation}: #{input} -> #{output}")
        FramerCore.CLI.main(cli_args)

      _ ->
        IO.puts(
          "Usage: mix framer.demo <input> <output> [--operation remove-bg|fps-boost|loop] [--workers N]"
        )
    end
  end
end
