defmodule Mix.Tasks.FpsBoost do
  use Mix.Task

  @shortdoc "Boost video framerate to target FPS through the Python Port worker"
  @moduledoc """
  Boosts the framerate of a video file.

  ## Usage
    mix fps_boost input_path output_path --to 60
  """

  def run(args) do
    # Ensure all apps are started (including framer_core which loads NIFs)
    Mix.Task.run("app.start")

    case args do
      [input, output | rest] ->
        FramerCore.CLI.main(["fps-boost", input, output | rest])

      _ ->
        IO.puts("Usage: mix fps_boost input_path output_path [--to target_fps]")
    end
  end
end
