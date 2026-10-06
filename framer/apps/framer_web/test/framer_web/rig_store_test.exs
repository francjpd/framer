defmodule FramerWeb.RigStoreTest do
  use ExUnit.Case, async: false

  alias FramerWeb.Rig
  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  setup_all do
    original = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_store_#{System.unique_integer([:positive])}")
    Application.put_env(:framer_web, :projects_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:framer_web, :projects_dir, original)
    end)

    {:ok, root: root}
  end

  test "create_from_source derives the canvas and writes the still", %{root: root} do
    binary = Fixtures.png_with_subject(48, 40)

    assert {:ok, rig} = RigStore.create_from_source(binary, "subject.png", name: "Subject")
    assert rig["name"] == "Subject"
    assert Rig.canvas(rig) == %{"width" => 48, "height" => 40}

    source = RigStore.source_path(rig["id"])
    assert source == Path.join([root, rig["id"], "source.png"])
    assert File.read!(source) == binary
  end

  test "save/load round-trips and list/delete work" do
    rig = Fixtures.simple_rig(64)
    assert {:ok, saved} = RigStore.save(rig)
    assert RigStore.load(saved["id"]) == {:ok, saved}

    summaries = RigStore.list()
    assert Enum.any?(summaries, &(&1.id == saved["id"]))
    assert Enum.find(summaries, &(&1.id == saved["id"])).bones == 1

    assert {:ok, _} = RigStore.delete(saved["id"])
    assert RigStore.load(saved["id"]) == {:error, :enoent}
  end

  test "output and result paths" do
    rig = Fixtures.simple_rig(16)
    {:ok, saved} = RigStore.save(rig)

    output = RigStore.output_path(saved["id"], "webm")
    assert Path.basename(output) == "output.webm"
    assert RigStore.result_path(saved["id"]) == nil

    File.write!(output, "video")
    assert RigStore.result_path(saved["id"]) == output
  end

  test "rejects unsafe ids" do
    assert {:error, :invalid_id} = RigStore.load("../escape")
    assert {:error, :invalid_id} = RigStore.save(%{"id" => "a/b", "schema" => "framer.rig"})
  end

  test "save refuses a document the engine would reject" do
    rig = Rig.new(32, 32) |> Map.put("version", 99)
    assert {:error, reason} = RigStore.save(rig)
    assert inspect(reason) =~ "version"
  end
end
