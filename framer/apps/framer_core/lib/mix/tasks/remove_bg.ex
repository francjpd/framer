defmodule Mix.Tasks.RemoveBg do
  use Mix.Task

  @shortdoc "Remove video background using Rust NIFs"
  @moduledoc """
  Removes the background from a video file.

  ## Usage
    mix remove_bg input_path output_path [options]

  ## Options
    --color <r,g,b>    Target color to remove (default: 0,255,0)
    --tolerance <n>     Color tolerance (default: 30)
    --edges <n>         Edge refinement strength (default: 5)
    --method <string>   Removal method: color, ml, etc. (default: color)
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
