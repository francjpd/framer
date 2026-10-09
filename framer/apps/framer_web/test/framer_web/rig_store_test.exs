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

  test "delete removes the whole project directory and is safe when already gone", %{
    root: root
  } do
    binary = Fixtures.png_with_subject(32, 32)
    {:ok, rig} = RigStore.create_from_source(binary, "subject.png", name: "Doomed")
    id = rig["id"]
    dir = RigStore.project_dir(id)

    output = RigStore.output_path(id, "webm")
    File.write!(output, "video")
    assert File.exists?(RigStore.rig_path(id))
    assert File.exists?(Path.join(dir, "source.png"))

    assert {:ok, _removed} = RigStore.delete(id)
    refute File.exists?(dir)
    refute Enum.any?(RigStore.list(), &(&1.id == id))

    # A second delete, when nothing is left on disk, still succeeds.
    assert {:ok, _removed} = RigStore.delete(id)

    # The id guard still applies: unsafe ids never leave the store root.
    assert {:error, :invalid_id} = RigStore.delete("../escape")
    assert File.exists?(root)
  end

  test "traversal-shaped ids cannot escape the store root and repeat deletes are harmless", %{
    root: root
  } do
    sibling = Path.join(Path.dirname(root), "framer_escape_#{System.unique_integer([:positive])}")
    File.mkdir_p!(sibling)
    on_exit(fn -> File.rm_rf(sibling) end)

    sentinel = Path.join(sibling, "keep.txt")
    File.write!(sentinel, "untouched")

    traversal = "../#{Path.basename(sibling)}"
    assert {:error, :invalid_id} = RigStore.delete(traversal)
    assert File.exists?(sentinel)
    assert File.exists?(root)

    {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
    id = rig["id"]
    assert {:ok, _} = RigStore.delete(id)
    assert {:ok, _} = RigStore.delete(id)
    refute File.exists?(RigStore.project_dir(id))
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
