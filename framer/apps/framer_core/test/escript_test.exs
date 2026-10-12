defmodule FramerCore.EscriptTest do
  @moduledoc """
  End-to-end test of the `framer` command.

  The escript is really built here - the same `mix escript.build` the CI build
  path and the docs use - and a real operation is then run through it, so the
  standalone binary, its baked configuration, the argument parsing, the
  orchestrator, the Python Port and the merge step are all exercised the way
  an agent (or a person) drives them. If this suite passes, `framer` cannot rot
  without a test failing.
  """

  use ExUnit.Case, async: false

  alias FramerCore.Catalog
  alias FramerCore.TestMedia

  @moduletag :integration
  @moduletag :requires_cv2
  @moduletag timeout: 600_000

  @app_root Path.expand("..", __DIR__)

  setup_all do
    tmp = Path.join(System.tmp_dir!(), "framer_escript_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    escript = Path.join(@app_root, build_escript!())
    clip = TestMedia.write_clip!(tmp)

    {:ok, tmp: tmp, escript: escript, clip: clip}
  end

  test "the catalog commands come out of the built escript", %{escript: escript} do
    {output, 0} = System.cmd(escript, ["list", "--json"])
    document = Jason.decode!(output)

    assert Enum.map(document["operations"], & &1["name"]) == Catalog.names()

    {describe, 0} = System.cmd(escript, ["describe", "remove-bg", "--json"])
    assert Jason.decode!(describe)["name"] == "remove-bg"
    assert Jason.decode!(describe)["usage"] == "framer remove-bg <input> <output> [options]"
  end

  test "an unknown operation exits non-zero with the command to discover them", %{
    escript: escript
  } do
    # Errors and diagnostics are written to stderr; on the failure path stdout
    # is empty, so merging the streams captures the whole explanation.
    {output, status} =
      System.cmd(escript, ["resize", "in.mp4", "out.mp4"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "unknown command"
    assert output =~ "framer list"
  end

  test "remove-bg keys a background through the whole command", %{
    escript: escript,
    clip: clip,
    tmp: tmp
  } do
    output = Path.join(tmp, "keyed.webm")

    {stdout, 0} = System.cmd(escript, ["remove-bg", clip, output, "--color", "0,255,0"])

    # stdout is the machine contract: exactly the output path.
    assert String.trim(stdout) == output
    assert File.exists?(output)

    {:ok, alpha} = TestMedia.decode_alpha(output)
    assert TestMedia.corner_alpha(alpha) == 0
    assert TestMedia.center_alpha(alpha) == 255
  end

  test "a bad invocation exits non-zero without producing output", %{
    escript: escript,
    clip: clip,
    tmp: tmp
  } do
    output = Path.join(tmp, "never_written.webm")

    {_out, status} =
      System.cmd(escript, ["remove-bg", clip, output, "--tolerance", "not-a-number"],
        stderr_to_stdout: true
      )

    assert status == 1
    refute File.exists?(output)
  end

  test "deform renders a rig document into an animation", %{
    escript: escript,
    tmp: tmp
  } do
    still = TestMedia.write_still!(tmp)
    rig = Path.join(tmp, "rig.json")
    output = Path.join(tmp, "deformed.webm")

    File.write!(rig, Jason.encode!(rig_document(tmp)))

    {stdout, 0} = System.cmd(escript, ["deform", still, output, "--rig", rig])

    assert String.trim(stdout) == output
    assert File.exists?(output)
  end

  # --- helpers ---

  # The build path is a command a human or CI runs (`cd framer/apps/framer_core
  # && mix escript.build`), so the test runs exactly that, in the current Mix
  # environment so the already-compiled build is reused.
  defp build_escript! do
    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: @app_root,
        env: [{"MIX_ENV", to_string(Mix.env())}],
        stderr_to_stdout: true
      )

    status == 0 || raise "mix escript.build failed (#{status}): #{output}"

    "framer"
  end

  defp rig_document(tmp) do
    %{
      "schema" => "framer.rig",
      "version" => 1,
      "canvas" => %{
        "width" => TestMedia.geometry().width,
        "height" => TestMedia.geometry().height
      },
      "source" => %{"kind" => "image", "path" => Path.join(tmp, "still.png"), "frame" => 0},
      "duration" => %{"fps" => 8, "frames" => 16},
      "bones" => [
        %{
          "id" => "b0",
          "name" => "root",
          "parent" => nil,
          "rest" => %{"head" => [80, 60], "tail" => [80, 20]},
          "radius" => 400,
          "falloff" => "smooth"
        }
      ],
      "bind" => %{"power" => 2.0, "radius_scale" => 1.0},
      "keyframes" => [
        %{"frame" => 0, "pose" => %{"b0" => %{"rot" => 0.0, "tx" => 0, "ty" => 0}}},
        %{"frame" => 15, "pose" => %{"b0" => %{"rot" => 0.0, "tx" => 30, "ty" => 0}}}
      ]
    }
  end
end
