defmodule Mix.Tasks.LoopOp do
  use Mix.Task

  @shortdoc "Create a seamless video loop through the Python Port worker"
  @moduledoc """
  Creates a looping version of a video.

  ## Usage
    mix loop_op input_path output_path [options]

  ## Options
    --method <string>    Looping method: pingpong, fade, morph (default: pingpong)
    --fade-frames <n>    Number of frames for fade transition
    --fade-color <r,g,b> Color for fade transition
    --morph-steps <n>    Number of steps for morph transition
    --hold-frames <n>    Number of frames to hold at the end
    --blend-mode <string> Blend mode for transitions
    --ramp-factor <f>    Ramp factor for speed adjustments
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
