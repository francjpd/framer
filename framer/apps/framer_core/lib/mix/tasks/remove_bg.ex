defmodule Mix.Tasks.RemoveBg do
  use Mix.Task

  @shortdoc "Remove video background through the Python Port worker"
  @moduledoc """
  Removes the background from a video file.

  A thin front-end over `FramerCore.CLI.main/1`; the options and their defaults
  are described by `framer describe remove-bg` (see `FramerCore.Catalog`).

  ## Usage

      mix remove_bg input_path output_path [options]
  """

  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [input, output | rest] ->
        FramerCore.CLI.main(["remove-bg", input, output | rest])

      _ ->
        IO.puts("Usage: mix remove_bg input_path output_path [options]")
    end
  end
end
