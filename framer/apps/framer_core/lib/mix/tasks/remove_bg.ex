defmodule Mix.Tasks.RemoveBg do
  use Mix.Task

  @shortdoc "Remove video background using Rust NIFs"
  @moduledoc """
  Removes the background from a video file.

  ## Usage

      mix remove_bg input_path output_path [options]

  ## Options

    * `--color <b,g,r>` - Target color (default: "0,255,0" = green)
    * `--tolerance <n>` - Color tolerance 0-255 (default: 30)
    * `--edges <n>` - Soft edge blur radius (default: 5)
    * `--method <string>` - Removal method: color, chromakey (default: color)
    * `--auto-ranges <bool>` - Auto-generate color ranges (default: true)
    * `--num-ranges <n>` - Number of color ranges (default: 5)
    * `--edge-cleanup <n>` - Edge cleanup iterations (default: 3)
    * `--refine <bool>` - Enable refinement pass (default: false)
    * `--refine-tolerance <n>` - Refinement tolerance (default: 45)

  ## Color Format

    * BGR comma-separated: "0,255,0" (blue=0, green=255, red=0)
    * Hex: "#00FF00" (RGB format, auto-converted)

  ## Examples

      mix remove_bg input.mp4 output.webm --color "0,255,0" --tolerance 30
      mix remove_bg input.mp4 output.webm --color "#00FF00" --auto-ranges true --num-ranges 5
      mix remove_bg input.mp4 output.webm --refine true --edge-cleanup 5
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
