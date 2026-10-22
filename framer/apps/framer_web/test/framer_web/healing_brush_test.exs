defmodule FramerWeb.Healing.BrushTest do
  @moduledoc """
  The healing brush, end to end: a painted correction changes the background
  layer with the feathered falloff the automatic patch uses, and the
  correction is stored in the corpus from its first use.

  The engine does the pixels - the BEAM only ever sends paths - so the
  assertions about the healed plate are read back with the engine's own
  Python, the same way the export is verified.

  What is pinned:

  1. **The background layer is what changes.** The correction lands in the
     project's background plate, which is the file the frame is composited
     over.
  2. **The falloff is the patch's falloff.** The correction ramps into the
     untouched background: the area the brush never reached is untouched, and
     the transition across the painted area is gradual rather than a hard
     edge.
  3. **The correction is stored on first use.** The corpus holds the content
     that was painted, the mask it covered and the pixels it replaced, so the
     training material exists from the very first correction.
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
  @artefact_y 16
  @brush_radius 12

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

    # 1. A project with a still.
    {:ok, rig} =
      RigStore.create_from_source(Fixtures.keyable_still(@size, @size), "still.png",
        name: "Healing brush"
      )

    id = rig["id"]

    # 2. Extract the character: the rig becomes split and the background
    #    plate is materialised beside the still.  The engine's own validator
    #    wants a skeleton, so the rig gets the same bone every project has.
    {rig, _bone_id} = Rig.add_bone(rig, [32, 48], [32, 16], radius: @size)
    rig = Rig.auto_bind(rig) |> Rig.enable_split()
    {:ok, character} = Renderer.split_character(rig)
    rig = Rig.set_character_layer(rig, Path.basename(character))
    {:ok, _rig} = RigStore.save(rig)

    # 3. The user replaces the background with one that still has a bad area:
    #    the automatic repair was not good enough here, which is exactly when
    #    the brush is the answer.
    {:ok, rig} =
      RigStore.replace_layer(
        id,
        :background,
        Fixtures.background_with_artefact(@size, @size),
        "background.png"
      )

    plate = RigStore.plate_path(id)
    assert plate, "the project has no background plate to heal"

    # The artefact is red before the correction.
    before = Fixtures.read_pixels(plate, [{@artefact_x, @artefact_y}])
    assert before["pixels"] |> hd() |> List.last() |> Enum.at(2) > 200

    # 4. Paint over the artefact and heal it. The correction is a normal
    #    editor operation: it is submitted like an export and polled.
    strokes = [%{"points" => [[@artefact_x + 4, @artefact_y]], "radius" => @brush_radius}]
    stored_before = Corpus.count()

    assert {:ok, %{job_id: job_id}} = Renderer.submit_heal(rig, strokes)
    assert is_binary(job_id)

    # 5. Wait for the correction to land and to be stored.
    assert wait_for_stored(stored_before), "the correction was never stored"

    # 6. The background layer is what changed, and the correction ramps into
    #    the untouched background instead of sitting on it as a hard edge.
    healed = Fixtures.read_pixels(plate, ramp_points())

    reds = Enum.map(healed["pixels"], fn [_x, _y, pixel] -> Enum.at(pixel, 2) end)

    # The falloff is the patch's own ramp: transparent at the edge of the
    # painted area, opaque in its middle.  The artefact therefore fades into
    # the surrounding ground instead of being cut out of it.
    expected = Enum.map(ramp_points(), fn {x, _y} -> expected_red(x) end)

    assert Enum.all?(Enum.zip(reds, expected), fn {actual, want} ->
             abs(actual - want) <= 30
           end),
           "the correction does not follow the patch's feathered falloff"

    assert List.first(reds) > 90, "the edge of the correction was overwritten"
    assert List.last(reds) < 45, "the painted area was not healed"
    assert reds == Enum.sort(reds, :desc), "the correction does not ramp into the background"

    distinct = reds |> Enum.uniq() |> length()
    assert distinct >= 4, "the correction was pasted on as a hard edge"

    # The ground the brush never reached is untouched.
    outside = Fixtures.read_pixels(plate, [{2, 2}, {60, 60}, {2, 60}])
    assert Enum.all?(outside["pixels"], fn [_x, _y, pixel] -> Enum.at(pixel, 2) < 60 end)

    # 7. The correction is stored from its first use: the content that was
    #    painted, the mask it covered and the pixels it replaced.
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
  end

  # The pixels along a line that crosses the painted area, from the artefact's
  # edge into the middle of the correction.
  defp ramp_points do
    for x <- @artefact_x..(@artefact_x + 4), do: {x, @artefact_y}
  end

  # The red the artefact is left with at `x`, if the correction follows the
  # patch's ramp: transparent at the edge of the painted area, opaque in its
  # middle.
  defp expected_red(x) do
    distance = abs(@artefact_x + 4 - x)
    ramp = max(0.0, (@brush_radius - distance - 1) / @brush_radius)
    round(255 * (1.0 - ramp))
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
