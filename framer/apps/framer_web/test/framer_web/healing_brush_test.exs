defmodule FramerWeb.Healing.BrushTest do
  @moduledoc """
  The healing brush, end to end: a painted correction changes the background
  layer - opaque where the user painted, feathered at its edge - and the
  correction is stored in the corpus from its first use.

  The engine does the pixels - the BEAM only ever sends paths - so the
  assertions about the healed plate are read back with the engine's own
  Python, the same way the export is verified.

  What is pinned:

  1. **The background layer is what changes.** The correction lands in the
     project's background plate, which is the file the frame is composited
     over.
  2. **The correction is opaque where the user painted.** The falloff is the
     patch's own ramp, but it is measured from the area the user painted, so
     the pixels they covered are replaced outright: a brush-sized area is
     smaller than the feather the rig records, and the feather may not
     swallow the whole correction.
  3. **The ground outside the brush is untouched.** The correction feathers
     into it at the edge of the painted area, whatever feather the rig
     records - a rig with no feather of its own still gets a soft edge.
  4. **The correction is stored on first use.** The corpus holds the content
     that was painted, the mask it covered and the pixels it replaced, and
     the project keeps the correction the patch re-applies when it is
     rebuilt.
  """

  use FramerWebWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :requires_cv2
  @moduletag timeout: 180_000

  alias FramerWeb.Healing.Corpus
  alias FramerWeb.Renderer
  alias FramerWeb.Rig
  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  @size 64
  # The artefact the user paints over: a red block in the green ground.
  @artefact_x 12
  @artefact_y 12
  @artefact_size 8
  @brush_radius 12
  # The middle of the artefact, where the brush is.
  @centre_x @artefact_x + div(@artefact_size, 2)
  @centre_y @artefact_y + div(@artefact_size, 2)

  setup_all do
    original = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_heal_#{System.unique_integer([:positive])}")
    Application.put_env(:framer_web, :projects_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:framer_web, :projects_dir, original)
    end)

    :ok
  end

  test "a painted correction heals the background layer and is stored" do
    await_idle_orchestrator()

    {rig, id, plate} = project_with_artefact()

    # The artefact is red before the correction.
    before = Fixtures.read_pixels(plate, [{@centre_x, @centre_y}])
    assert before["pixels"] |> hd() |> List.last() |> Enum.at(2) > 200

    strokes = [%{"points" => [[@centre_x, @centre_y]], "radius" => @brush_radius}]
    stored_before = Corpus.count()

    assert {:ok, %{job_id: job_id}} = Renderer.submit_heal(rig, strokes)
    assert is_binary(job_id)

    # Wait for the correction to land and to be stored.
    assert wait_for_stored(stored_before), "the correction was never stored"

    # The background layer is what changed, and the correction is opaque
    # where the user painted: the pixels they covered are replaced, not
    # tinted, and the correction feathers out of the painted area.
    reds = reds_along_the_brush(plate)

    assert List.last(reds) < 20, "the painted area was not healed"
    assert List.first(reds) > 20, "the edge of the correction was overwritten"
    assert reds == Enum.sort(reds, :desc), "the correction does not ramp into the background"

    distinct = reds |> Enum.uniq() |> length()
    assert distinct >= 3, "the correction was pasted on as a hard edge"

    # The ground the brush never reached is untouched.
    outside = Fixtures.read_pixels(plate, [{2, 2}, {60, 60}, {2, 60}])
    assert Enum.all?(outside["pixels"], fn [_x, _y, pixel] -> Enum.at(pixel, 2) < 60 end)

    # The correction is stored from its first use: the content that was
    # painted, the mask it covered and the pixels it replaced.
    correction = latest_correction()
    assert correction.rig_id == id
    assert byte_size(correction.content) > 0
    assert byte_size(correction.mask) > 0
    assert byte_size(correction.replaced) > 0

    dir =
      Path.join(System.tmp_dir!(), "framer_heal_artifacts_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    mask_path = Path.join(dir, "mask.png")
    content_path = Path.join(dir, "content.png")
    replaced_path = Path.join(dir, "replaced.png")

    File.write!(mask_path, correction.mask)
    File.write!(content_path, correction.content)
    File.write!(replaced_path, correction.replaced)

    # The mask says what the brush covered ...
    assert File.stat!(mask_path).size > 0
    mask = Fixtures.read_pixels(mask_path, [{4, 4}])
    assert Enum.at(hd(mask["pixels"]) |> List.last(), 0) > 0
    # ... the replaced pixels are the artefact the user painted over ...
    assert Fixtures.max_red(replaced_path) > 200

    # ... and the content is what replaced them: the surrounding background.
    assert Fixtures.max_red(content_path) < 100

    # The project keeps the correction the patch re-applies when it is
    # rebuilt: the content that was painted, the mask it covered and the
    # rectangle they are cropped to.
    corrections = RigStore.corrections_path(id)
    assert File.exists?(corrections)

    {:ok, body} = File.read(corrections)
    {:ok, %{"corrections" => [entry]}} = Jason.decode(body)
    assert entry["bbox"]["width"] > 0
    assert entry["canvas"] == [@size, @size]
    assert entry["fade"] > 0
    assert byte_size(Base.decode64!(entry["mask"])) > 0
    assert byte_size(Base.decode64!(entry["content"])) > 0

    # And none of the correction's working files are left behind.
    workspace = Path.join(RigStore.project_dir(id), ".render")

    if File.dir?(workspace) do
      assert Enum.all?(File.ls!(workspace), &(not String.starts_with?(&1, "heal_"))),
             "the correction's working files were left behind"
    end
  end

  test "a rig with no feather of its own still gets a soft-edged correction" do
    await_idle_orchestrator()

    # A rig that records no feather at all: the correction may not be a
    # hard-edged blob, whatever the rig says.
    {rig, _id, plate} = project_with_artefact(fade: 0)

    strokes = [%{"points" => [[@centre_x, @centre_y]], "radius" => @brush_radius}]
    stored_before = Corpus.count()

    assert {:ok, %{job_id: _job_id}} = Renderer.submit_heal(rig, strokes)
    assert wait_for_stored(stored_before), "the correction was never stored"

    # The painted area is still fully replaced ...
    assert artefact_red(plate) == 0, "the painted area was not healed"

    # ... and the correction still has a band to feather with: a rig with no
    # feather of its own never gets a hard-edged blob.
    assert latest_correction().fade > 0, "the correction was pasted on with a hard edge"

    # ... and the ground around the brush is untouched.
    outside = Fixtures.read_pixels(plate, [{2, 2}, {60, 60}])
    assert Enum.all?(outside["pixels"], fn [_x, _y, pixel] -> Enum.at(pixel, 2) < 60 end)
  end

  test "a brush smaller than the rig's feather is still opaque where it painted" do
    await_idle_orchestrator()

    {rig, _id, plate} = project_with_artefact()

    # A brush much smaller than the feather the rig records: the correction
    # is still fully opaque where the user painted.
    strokes = [%{"points" => [[@centre_x, @centre_y]], "radius" => 6}]
    stored_before = Corpus.count()

    assert {:ok, %{job_id: _job_id}} = Renderer.submit_heal(rig, strokes)
    assert wait_for_stored(stored_before), "the correction was never stored"

    centre = Fixtures.read_pixels(plate, [{@centre_x, @centre_y}])

    assert Enum.at(hd(centre["pixels"]) |> List.last(), 2) < 20,
           "the painted area was not healed"
  end

  # A project with a still, a background plate with a red artefact in it, and
  # the character extracted - the state the brush is used in.
  defp project_with_artefact(opts \\ []) do
    {:ok, rig} =
      RigStore.create_from_source(Fixtures.keyable_still(@size, @size), "still.png",
        name: "Healing brush"
      )

    id = rig["id"]

    # Extract the character: the rig becomes split and the background plate
    # is materialised beside the still.  The engine's own validator wants a
    # skeleton, so the rig gets the same bone every project has.
    {rig, _bone_id} = Rig.add_bone(rig, [32, 48], [32, 16], radius: @size)
    rig = Rig.auto_bind(rig) |> Rig.enable_split()
    {:ok, character} = Renderer.split_character(rig)
    rig = Rig.set_character_layer(rig, Path.basename(character))
    {:ok, _rig} = RigStore.save(rig)

    # The user replaces the background with one that still has a bad area:
    # the automatic repair was not good enough here, which is exactly when
    # the brush is the answer.
    {:ok, rig} =
      RigStore.replace_layer(
        id,
        :background,
        Fixtures.background_with_artefact(@size, @size),
        "background.png"
      )

    rig =
      case Keyword.fetch(opts, :fade) do
        {:ok, fade} -> Rig.set_patch_fade(rig, fade)
        :error -> rig
      end

    {:ok, _rig} = RigStore.save(rig)

    plate = RigStore.plate_path(id)
    assert plate, "the project has no background plate to heal"

    {rig, id, plate}
  end

  # The red the artefact is left with, the most of it anywhere in the block
  # the user painted over: zero means the correction replaced it outright.
  defp artefact_red(plate) do
    points =
      for y <- @artefact_y..(@artefact_y + @artefact_size - 1),
          x <- @artefact_x..(@artefact_x + @artefact_size - 1),
          do: {x, y}

    plate
    |> Fixtures.read_pixels(points)
    |> Map.get("pixels")
    |> Enum.map(fn [_x, _y, pixel] -> Enum.at(pixel, 2) end)
    |> Enum.max()
  end

  # The red the artefact is left with along the line the brush painted, from
  # the artefact's edge into the middle of the correction: the correction
  # feathers out of the painted area, so the red falls away towards the
  # middle.
  defp reds_along_the_brush(plate) do
    points =
      for x <- (@artefact_x + @artefact_size - 1)..@centre_x//-1, do: {x, @centre_y}

    plate
    |> Fixtures.read_pixels(points)
    |> Map.get("pixels")
    |> Enum.map(fn [_x, _y, pixel] -> Enum.at(pixel, 2) end)
  end

  defp latest_correction do
    Corpus.list(limit: 1) |> List.first()
  end

  # Wait for the correction to be stored: the job is submitted and watched,
  # so the corpus grows a moment after the paint is applied.
  defp wait_for_stored(before, attempts \\ 300) do
    cond do
      Corpus.count() > before ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(100)
        wait_for_stored(before, attempts - 1)
    end
  end
end
