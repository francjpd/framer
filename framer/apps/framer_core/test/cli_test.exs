defmodule FramerCore.CLITest do
  @moduledoc """
  The `framer` surface without the BEAM doing any work: the catalog commands,
  the dispatch and the error paths. Real operations are covered by
  `FramerCore.EscriptTest` (through the built escript) and by the Port
  integration suites.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FramerCore.CLI
  alias FramerCore.Catalog

  # What a client actually sees: the catalog after a JSON round-trip, so types
  # and atoms have already been widened.
  defp json_document(term), do: term |> Jason.encode!() |> Jason.decode!()

  describe "list" do
    test "prints every operation as text on stdout" do
      out = capture_io(fn -> assert {:ok, _} = CLI.run(["list"]) end)

      for operation <- Catalog.operations() do
        assert out =~ operation.name
        assert out =~ operation.summary
        assert out =~ Catalog.usage(operation)
      end

      assert out =~ "framer describe <operation>"
    end

    test "--json prints the machine-readable catalog on stdout" do
      out = capture_io(fn -> assert {:ok, _} = CLI.run(["list", "--json"]) end)

      document = Jason.decode!(out)
      assert document["name"] == "framer"
      assert Enum.map(document["operations"], & &1["name"]) == Catalog.names()
      assert document == json_document(Catalog.list_json())
    end

    test "anything other than --json is an error" do
      assert {:error, message} = CLI.run(["list", "--yaml"])
      assert message =~ "--json"
    end
  end

  describe "describe" do
    test "prints one operation's contract" do
      out = capture_io(fn -> assert {:ok, _} = CLI.run(["describe", "deform"]) end)

      assert out =~ "deform"
      assert out =~ "framer deform <input> <output> [options]"
      assert out =~ "--rig, -r <PATH>"
    end

    test "--json prints the same entry the list uses" do
      out = capture_io(fn -> assert {:ok, _} = CLI.run(["describe", "deform", "--json"]) end)

      assert Jason.decode!(out) == json_document(Catalog.entry_json(Catalog.get("deform")))
    end

    test "an unknown operation is an error and points at list" do
      assert {:error, message} = CLI.run(["describe", "resize"])
      assert message =~ "unknown operation"
      assert message =~ "framer list"
    end

    test "without an operation name it is an unknown command" do
      assert {:error, message} = CLI.run(["describe"])
      assert message =~ "unknown command"
    end
  end

  describe "operation dispatch" do
    test "a catalogued operation parses its arguments before anything runs" do
      assert {:error, message} = CLI.run(["remove-bg", "in.mp4"])
      assert message =~ "missing <output>"

      assert {:error, message} = CLI.run(["remove-bg", "in.mp4", "out.webm", "--tolernace", "3"])
      assert message =~ "--tolerance"
    end

    test "an unknown command is rejected and suggests the closest operation" do
      assert {:error, message} = CLI.run(["deformm", "in.png", "out.webm", "--rig", "rig.json"])
      assert message =~ "unknown command"
      assert message =~ "did you mean deform?"
    end
  end

  describe "help and version" do
    test "the top-level help goes to stderr and lists every operation" do
      out = capture_io(:stderr, fn -> assert {:ok, _} = CLI.run([]) end)

      assert out =~ "framer #{Catalog.version()}"
      assert out =~ "framer list [--json]"

      for operation <- Catalog.operations() do
        assert out =~ operation.name
      end
    end

    test "an operation's --help prints its contract" do
      out = capture_io(fn -> assert {:ok, _} = CLI.run(["deform", "--help"]) end)
      assert out =~ "framer deform <input> <output> [options]"
    end

    test "--version prints the catalog version" do
      out = capture_io(fn -> assert {:ok, _} = CLI.run(["--version"]) end)
      assert out =~ Catalog.version()
    end
  end

  describe "info" do
    @tag :requires_cv2
    test "probes a video through the Port" do
      tmp = Path.join(System.tmp_dir!(), "framer_cli_info_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      clip = FramerCore.TestMedia.write_clip!(tmp)
      geometry = FramerCore.TestMedia.geometry()

      out = capture_io(fn -> assert {:ok, _} = CLI.run(["info", clip]) end)

      assert out =~ clip
      assert out =~ "#{geometry.width}x#{geometry.height}"
      assert out =~ "Frames: #{geometry.frames}"
    end
  end
end
