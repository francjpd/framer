defmodule FramerCore.ArgsTest do
  @moduledoc """
  The catalog declares every operation's arguments and options, so the parser
  is tested against a catalog entry rather than a hand-written grammar.
  """

  use ExUnit.Case, async: true

  alias FramerCore.Args
  alias FramerCore.Catalog

  defp parse(argv, operation \\ "remove-bg") do
    with {:ok, parsed} <- Args.parse(Catalog.get(operation), argv) do
      parsed
    else
      {:error, message} -> flunk("parsing failed: #{message}")
    end
  end

  test "positional arguments bind to the declared names" do
    parsed = parse(["in.mp4", "out.webm"])
    assert parsed.positional == %{"input" => "in.mp4", "output" => "out.webm"}
  end

  test "an unknown option is rejected with the closest known flag" do
    assert {:error, message} =
             Args.parse(Catalog.get("remove-bg"), ["in.mp4", "out.webm", "--colour", "0,255,0"])

    assert message =~ ~s(unknown option "--colour")
    assert message =~ "(did you mean --color?)"
  end

  test "a type error names the flag and the value" do
    assert {:error, message} =
             Args.parse(Catalog.get("remove-bg"), ["in.mp4", "out.webm", "--tolerance", "abc"])

    assert message =~ "--tolerance"
    assert message =~ ~s(got "abc")
  end

  test "an enum value is validated against the declared choices" do
    assert {:error, message} =
             Args.parse(Catalog.get("remove-bg"), ["in.mp4", "out.webm", "--method", "chroma"])

    assert message =~ "one of color, motion, combined"
  end

  test "a required option without a default is enforced" do
    assert {:error, message} = Args.parse(Catalog.get("deform"), ["still.png", "out.webm"])
    assert message =~ "missing required option --rig"

    parsed = parse(["still.png", "out.webm", "--rig", "rig.json"], "deform")
    assert parsed.options["rig"] == "rig.json"
  end

  test "too many and too few positional arguments are rejected" do
    assert {:error, message} =
             Args.parse(Catalog.get("loop"), ["in.mp4", "out.webm", "extra.mp4"])

    assert message =~ "unexpected"

    assert {:error, message} = Args.parse(Catalog.get("loop"), ["in.mp4"])
    assert message =~ "missing <output>"
  end

  test "declared defaults fill in what was not given" do
    parsed = parse(["in.mp4", "out.webm"])

    assert parsed.options["tolerance"] == 30
    assert parsed.options["edges"] == 5
    assert parsed.options["method"] == "color"
    assert parsed.options["auto_ranges"] == true
    assert parsed.options["refine"] == false
  end

  test "given values override the defaults" do
    parsed = parse(["in.mp4", "out.webm", "--tolerance", "60", "--edges", "0"])

    assert parsed.options["tolerance"] == 60
    assert parsed.options["edges"] == 0
  end

  test "an option without a default stays absent rather than nil" do
    parsed = parse(["in.mp4", "out.webm"])

    refute Map.has_key?(parsed.options, "color")
  end

  test "options may be given in any order, including before the positionals" do
    parsed = parse(["--color", "0,255,0", "--tolerance", "40", "in.mp4", "out.webm"])

    assert parsed.positional == %{"input" => "in.mp4", "output" => "out.webm"}
    assert parsed.options["color"] == "0,255,0"
    assert parsed.options["tolerance"] == 40
  end

  test "short flags and --flag=value are accepted" do
    parsed = parse(["in.mp4", "out.webm", "-c", "0,255,0", "-t=25"])

    assert parsed.options["color"] == "0,255,0"
    assert parsed.options["tolerance"] == 25
  end

  test "a boolean flag is true on its own and takes a literal" do
    assert parse(["in.mp4", "out.webm", "--refine"]).options["refine"]
    assert parse(["in.mp4", "out.webm", "--refine", "false"]).options["refine"] == false
    assert parse(["in.mp4", "out.webm", "--auto-ranges=false"]).options["auto_ranges"] == false

    # A boolean flag must not swallow the positional that follows it.
    parsed = parse(["in.mp4", "out.webm", "--refine"])
    assert parsed.positional["output"] == "out.webm"
  end

  test "a missing option value is reported instead of eating the next token" do
    assert {:error, message} = Args.parse(Catalog.get("remove-bg"), ["--color"])
    assert message =~ "--color: missing value"

    assert {:error, message} =
             Args.parse(Catalog.get("remove-bg"), ["in.mp4", "out.webm", "--color", "--tolerance"])

    assert message =~ "--color: missing value"
  end

  test "numbers are parsed as numbers" do
    parsed = parse(["in.mp4", "out.mp4", "--to", "48"], "fps-boost")
    assert parsed.options["to"] == 48

    parsed =
      parse(["still.png", "out.webm", "--rig", "rig.json", "--radius-scale", "1.5"], "deform")

    assert parsed.options["radius_scale"] == 1.5
  end
end
