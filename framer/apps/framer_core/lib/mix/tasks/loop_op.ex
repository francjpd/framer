defmodule Mix.Tasks.LoopOp do
  use Mix.Task

  @shortdoc "Create a seamless video loop through the Python Port worker"
  @moduledoc """
  Creates a looping version of a video.

  A thin front-end over `FramerCore.CLI.main/1`; the options and their defaults
  are described by `framer describe loop` (see `FramerCore.Catalog`).

  ## Usage
    mix loop_op input_path output_path [options]
  """

  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [input, output | rest] ->
        FramerCore.CLI.main(["loop", input, output | rest])

      _ ->
        IO.puts("Usage: mix loop_op input_path output_path [options]")
    end
  end
end
