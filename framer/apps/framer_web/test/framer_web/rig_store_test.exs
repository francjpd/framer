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

  test "the character layer is stored, read and removed beside the still" do
    rig = Fixtures.simple_rig(32)
    {:ok, saved} = RigStore.save(rig)
    id = saved["id"]

    assert RigStore.character_layer_path(id) == nil
    assert RigStore.plate_path(id) == nil

    layer = Path.join(RigStore.project_dir(id), Rig.layer_filename())
    File.write!(layer, "cutout")
    assert RigStore.character_layer_path(id) == layer

    assert :ok = RigStore.remove_character_layer(id)
    assert RigStore.character_layer_path(id) == nil

    # Removing an absent layer is harmless, and an unsafe id never escapes.
    assert :ok = RigStore.remove_character_layer(id)
    assert :ok = RigStore.remove_character_layer("../escape")
  end

  test "removing the character layer clears every file the engine could resolve" do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    id = rig["id"]
    dir = RigStore.project_dir(id)

    split = Rig.enable_split(rig, character: "cutouts/hero.png")
    assert {:ok, _saved} = RigStore.save(split)

    declared = Path.join(dir, "cutouts/hero.png")
    File.mkdir_p!(Path.dirname(declared))
    File.write!(declared, "cutout")

    # The stale default-named cut-out from an earlier split is still on disk, so
    # the engine would reuse it when the document stops declaring a path...
    stale_default = Path.join(dir, Rig.layer_filename())
    File.write!(stale_default, "stale cutout")
    # ...together with the plate built from it.
    plate = Path.join(dir, Rig.plate_filename())
    File.write!(plate, "plate")

    assert :ok = RigStore.remove_character_layer(id)

    refute File.exists?(declared)
    refute File.exists?(stale_default)
    refute File.exists?(plate)
    assert RigStore.character_layer_path(id) == nil
    assert RigStore.plate_path(id) == nil
  end

  test "the plate path resolves the materialised background layer" do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    id = rig["id"]

    plate = Path.join(RigStore.project_dir(id), Rig.plate_filename())
    File.write!(plate, "plate")

    assert RigStore.plate_path(id) == plate
    assert RigStore.plate_path("../escape") == nil
  end

  test "the patch path resolves the materialised patch layer" do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    id = rig["id"]

    # Nothing materialised yet.
    assert RigStore.patch_path(id) == nil
    assert RigStore.patch_version(id) == nil

    patch = Path.join(RigStore.project_dir(id), Rig.patch_filename())
    File.write!(patch, "patch")

    assert RigStore.patch_path(id) == patch
    assert is_binary(RigStore.patch_version(id))
    assert RigStore.patch_path("../escape") == nil
  end

  test "character layer paths honour the declared layer path" do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    id = rig["id"]

    split = Rig.enable_split(rig, character: "cutouts/hero.png")
    assert {:ok, saved} = RigStore.save(split)
    assert saved["id"] == id

    assert RigStore.character_layer_path(id) == nil

    layer = Path.join(RigStore.project_dir(id), "cutouts/hero.png")
    File.mkdir_p!(Path.dirname(layer))
    File.write!(layer, "cutout")

    assert RigStore.character_layer_path(id) == layer

    assert :ok = RigStore.remove_character_layer(id)
    refute File.exists?(layer)
    assert RigStore.character_layer_path(id) == nil
  end

  test "a split rig saves and loads with its layered state round-tripped" do
    {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")

    split =
      rig
      |> Rig.enable_split(tolerance: 55)
      |> Rig.set_character_layer("hero.png")

    assert {:ok, saved} = RigStore.save(split)
    assert RigStore.load(saved["id"]) == {:ok, saved}

    loaded = elem(RigStore.load(saved["id"]), 1)
    assert Rig.split?(loaded)
    assert get_in(loaded, ["layers", "tolerance"]) == 55
    assert Rig.character_layer(loaded) == "hero.png"

    # Turning it back off round-trips as the single-picture document it was.
    assert {:ok, cleared} = RigStore.save(Rig.clear_layers(loaded))
    assert RigStore.load(cleared["id"]) == {:ok, cleared}
    refute Rig.split?(elem(RigStore.load(cleared["id"]), 1))
  end

  test "character_layer_path and plate_path respect layer removal in rig document" do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    id = rig["id"]
    dir = RigStore.project_dir(id)

    char_file = Path.join(dir, Rig.layer_filename())
    plate_file = Path.join(dir, Rig.plate_filename())
    File.write!(char_file, "cutout")
    File.write!(plate_file, "plate")

    # Before removal, both paths exist
    assert RigStore.character_layer_path(id) == char_file
    assert RigStore.plate_path(id) == plate_file

    # Remove background
    removed_bg = rig |> Rig.enable_split() |> Rig.remove_layer("background")
    assert {:ok, _} = RigStore.save(removed_bg)
    assert RigStore.plate_path(id) == nil
    assert RigStore.character_layer_path(id) == char_file

    # Remove character
    removed_char = removed_bg |> Rig.remove_layer("character")
    assert {:ok, _} = RigStore.save(removed_char)
    assert RigStore.character_layer_path(id) == nil
    assert RigStore.plate_path(id) == nil

    # Keep background again
    kept_bg = Rig.keep_layer(removed_char, "background")
    assert {:ok, _} = RigStore.save(kept_bg)
    assert RigStore.plate_path(id) == plate_file
  end

  test "replace_layer updates source, character, and background layers" do
    {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
    id = rig["id"]

    new_img = Fixtures.png(16, 16)

    # Replace character
    assert {:ok, updated_char} = RigStore.replace_layer(id, :character, new_img, "new_char.png")
    assert Rig.has_character_layer?(updated_char)
    assert Rig.character_layer(updated_char) == "character_replaced.png"
    assert File.exists?(RigStore.character_layer_path(id))

    # Replace background
    assert {:ok, updated_bg} = RigStore.replace_layer(id, :background, new_img, "new_bg.png")
    assert Rig.has_background_layer?(updated_bg)
    assert Rig.background_layer(updated_bg) == "background_replaced.png"
    assert File.exists?(RigStore.plate_path(id))

    # Replace source
    assert {:ok, updated_src} = RigStore.replace_layer(id, :source, new_img, "new_src.png")
    assert get_in(updated_src, ["source", "path"]) == "source_replaced.png"
  end
end
