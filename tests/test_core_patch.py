"""
Proof: the feathered background patch keeps a background-backed frame opaque.

The patch is the third materialised layer: the character, then the feathered
reconstruction of the region the character can uncover, then the opaque plate.
This file drives the real engine operation (`ops.deform.deform_video`, the same
code the editor's "Render frame" action runs through the Port contract) over
the deterministic scene from `tests/layer_scene.py`, so what it asserts is what
an end user sees.

What is pinned:

1. **The region is the swept area.** The union of the character's warped
   footprints over the timeline, minus its own rest footprint - the strip the
   character travels into, and not the block it started on.
2. **The feather is a ramp.** Fully opaque in the middle of the region, clear
   at its edge, so the patch merges into the untouched background around it.
3. **The frame stays opaque.** The patch carries the feather, the plate does
   not, so a background-backed render has no transparent pixel at all.
4. **The reconstruction comes from the plate.** A plate the user replaced is
   the material the patch is built from, so the character's own pixels never
   bleed into it.
5. **An old rig is untouched.** A document that records no fade renders
   byte-for-byte as it did before the patch existed.
6. **The patch is a project-level artefact.** It is materialised once, reused
   by every later render, and rebuilt when the rig it came from changes - or
   when either of the layers it is built from is replaced.
7. **The region is the whole swept area.** It has no hole where the character
   travels, and a rig without the plate has no patch at all.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.bg_removal import character_alpha
from core.deform import DeformRenderer, load_or_build_weights, validate_rig
from core.layers import (
    PATCH_FILENAME,
    PLATE_FILENAME,
    has_patch_layer,
    load_layer,
    patch_fade,
    split_layers,
)
from core.patch import (
    build_patch,
    character_region,
    feather_ramp,
    patch_fingerprint,
    read_patch_meta,
)
from ops.deform import deform_video
from tests.layer_scene import FRAMES, SHIFT, SIZE, build_scene, write_scene

CHARACTER_ROWS = slice(32, 48)
CHARACTER_COLUMNS = slice(8, 24)
FADE = 12


def scene_rig(fade: int | None = FADE) -> tuple[dict, np.ndarray]:
    """The deterministic scene, optionally asking for a patch layer."""
    rig, source = build_scene()
    if fade is not None:
        rig["layers"]["fade"] = fade
    return rig, source


def scene_alpha(source: np.ndarray) -> np.ndarray:
    """The character's mask, as the engine computes it."""
    return character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)


def fast_scene() -> tuple[dict, np.ndarray]:
    """
    A character that travels almost its own width in a single frame.

    The region is the union of the character's warped footprints over the
    *whole* timeline, so the footprints have to overlap for the union to be
    continuous.  A timeline sampled with a stride would leave a hole wherever
    the character moved further between two sampled frames than its own
    footprint is wide.
    """
    size = 64
    frames = 5
    shift = 10

    source = np.zeros((size, size, 4), dtype=np.uint8)
    band = 190 + (np.arange(size) % 3)
    source[:, :, 1] = band[None, :]
    source[:, :, 3] = 255
    source[16:28, 4:16] = (0, 0, 255, 255)

    rig = {
        "schema": "framer.rig",
        "version": 1,
        "id": "fast-scene",
        "name": "Fast scene",
        "canvas": {"width": size, "height": size},
        "source": {"kind": "image", "path": "source.png", "frame": 0},
        "duration": {"fps": 12, "frames": frames},
        "mesh": {"mode": "grid", "vertices": [], "triangles": [], "weights": []},
        "bones": [
            {
                "id": "b0",
                "name": "spine",
                "parent": None,
                "rest": {"head": [10, 28], "tail": [10, 16]},
                "radius": size,
                "falloff": "smooth",
            }
        ],
        "bind": {"mode": "auto", "power": 2.0, "radius_scale": 1.0},
        "keyframes": [
            {"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}}},
            {
                "frame": frames - 1,
                "pose": {"b0": {"rot": 0.0, "tx": shift * (frames - 1), "ty": 0}},
            },
        ],
        "playback": {"loop": True},
        "layers": {
            "split": True,
            "character": "character.png",
            "tolerance": 40,
            "soft_edges": 0,
            "edge_cleanup": 0,
        },
    }
    validate_rig(rig)
    return rig, source


def render(directory: Path, rig: dict, frame: int, tag: str) -> np.ndarray:
    """Render one frame through the real operation and read it back."""
    rig_path = directory / f"{tag}.json"
    rig_path.write_text(json.dumps(rig))
    output = directory / f"{tag}_{frame}.png"
    result = deform_video(
        input_path=str(directory / "source.png"),
        output_path=str(output),
        rig=str(rig_path),
        start_frame=frame,
        end_frame=frame,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert result["success"], result.get("error")
    image = cv2.imread(str(output), cv2.IMREAD_UNCHANGED)
    assert image is not None
    return image


@pytest.fixture
def project(tmp_path: Path):
    _source_path, _rig_path = write_scene(tmp_path)
    return tmp_path


def test_the_region_is_the_area_the_character_can_uncover():
    """The union of the warped footprints, minus the rest footprint."""
    rig, source = scene_rig()
    alpha = scene_alpha(source)
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)

    region = character_region(rig, alpha, weights=weights)
    assert region.shape == (SIZE, SIZE)
    assert region.max() == 255

    # The strip the character travels into is inside the region...
    assert region[CHARACTER_ROWS, CHARACTER_COLUMNS.stop : CHARACTER_COLUMNS.stop + SHIFT].any()
    # ...and the block it started on is not: the rest footprint keeps the
    # plate's own reconstruction of it.
    assert not region[CHARACTER_ROWS, CHARACTER_COLUMNS.start : CHARACTER_COLUMNS.stop].any()
    # The background the character never reaches is not in the region either.
    assert not region[: CHARACTER_ROWS.start - 4].any()


def test_the_feather_ramp_is_opaque_in_the_middle_and_clear_at_the_edge():
    """The shared primitive: a ramp over the region, `fade` pixels wide."""
    region = np.zeros((80, 80), np.uint8)
    region[20:60, 20:60] = 255

    ramp = feather_ramp(region, FADE)
    assert ramp.shape == region.shape
    # Outside the region the patch is clear...
    assert (ramp[region == 0] == 0).all()
    # ...and so is the region's own edge, so it merges into the untouched
    # background around it.
    assert (ramp[20, 20:60] == 0).all()
    assert (ramp[59, 20:60] == 0).all()
    assert (ramp[20:60, 20] == 0).all()
    assert (ramp[20:60, 59] == 0).all()
    # The middle is fully opaque: the patch covers the region the character
    # travels through.
    assert (ramp[40, 33:47] == 255).all()
    assert (ramp[33:47, 40] == 255).all()
    # And the ramp between the two rises towards the middle and falls again.
    column = ramp[20:60, 40].astype(int)
    half = len(column) // 2
    assert (np.diff(column[: half + 1]) >= 0).all()
    assert (np.diff(column[half:]) <= 0).all()
    assert 0 < column.max() <= 255


def test_the_ramp_over_the_real_region_starts_clear_at_its_edge():
    rig, source = scene_rig()
    alpha = scene_alpha(source)
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)
    region = character_region(rig, alpha, weights=weights)

    ramp = feather_ramp(region, FADE)
    edge = np.zeros_like(region, bool)
    edge[1:-1, 1:-1] = (region[1:-1, 1:-1] > 0) & (
        (region[:-2, 1:-1] == 0)
        | (region[2:, 1:-1] == 0)
        | (region[1:-1, :-2] == 0)
        | (region[1:-1, 2:] == 0)
    )
    edge[0, :] = region[0, :] > 0
    edge[-1, :] = region[-1, :] > 0
    edge[:, 0] = region[:, 0] > 0
    edge[:, -1] = region[:, -1] > 0

    assert edge.any()
    assert (ramp[edge] == 0).all()
    assert (ramp[region == 0] == 0).all()


def test_a_fade_of_zero_is_no_feather_at_all():
    rig, source = scene_rig()
    alpha = scene_alpha(source)
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)
    region = character_region(rig, alpha, weights=weights)

    ramp = feather_ramp(region, 0)
    assert set(np.unique(ramp)) <= {0, 255}
    assert (ramp[region > 0] == 255).all()
    assert (ramp[region == 0] == 0).all()


def test_the_rendered_frame_has_no_transparent_pixel(project: Path):
    """The feather lives on the patch, so the plate underneath stays opaque."""
    rig, _source = scene_rig()
    for frame in (0, FRAMES - 1):
        image = render(project, rig, frame, "patched")
        assert (image[:, :, 3] == 255).all()


def test_the_patch_is_built_from_the_plate_not_from_the_still(project: Path):
    """
    A plate the user replaced is the material the reconstruction comes from.

    Inpainting from the still would leak the character's own pixels into the
    result; the plate holds background only, so the patch carries the plate's
    material instead.
    """
    rig, _source = scene_rig()
    # The first render materialises the character layer and the plate; the
    # plate is then replaced by hand, the way a user would.
    render(project, rig, 0, "replaced")

    plate = np.zeros((SIZE, SIZE, 4), np.uint8)
    plate[:, :, 0] = 200  # a blue plate, nothing like the still's green band
    plate[:, :, 3] = 255
    assert cv2.imwrite(str(project / PLATE_FILENAME), plate)
    (project / PATCH_FILENAME).unlink()

    image = render(project, rig, 0, "replaced")

    # The strip the character travels into shows the plate's blue, not the
    # still's green band.
    swept = image[CHARACTER_ROWS, CHARACTER_COLUMNS.stop : CHARACTER_COLUMNS.stop + SHIFT]
    assert (swept[:, :, 0] > 100).all()
    # The background the character never reaches is the plate's blue as well.
    assert (image[:20, :, 0] == 200).all()


def test_the_patch_carries_no_character_colour():
    """The patch is reconstructed from background-only pixels."""
    rig, source = scene_rig()
    alpha = scene_alpha(source)
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)
    _character, plate = split_layers(source, alpha)

    patch = build_patch(rig, alpha, plate, fade=FADE, weights=weights)
    assert patch.shape == (SIZE, SIZE, 4)
    # The still's character is pure red; the patch holds none of it.
    assert not patch[:, :, 2].any()


def test_an_old_rig_without_a_fade_renders_exactly_as_before(project: Path):
    """A document saved before the patch existed keeps rendering as it did."""
    rig, _source = scene_rig(fade=None)
    assert not has_patch_layer(rig)
    assert patch_fade(rig) is None

    legacy = render(project, rig, FRAMES - 1, "legacy")
    assert (legacy[:, :, 3] == 255).all()
    assert not (project / PATCH_FILENAME).exists()

    # The very same rig with a fade recorded renders the same frame: on a flat
    # background the patch reproduces the ground the character uncovers, so it
    # changes nothing.
    patched_rig, _ = scene_rig()
    patched = render(project, patched_rig, FRAMES - 1, "patched")
    assert np.array_equal(legacy, patched)


def test_the_patch_is_materialised_once_beside_the_still_and_then_reused(project: Path):
    """The patch is a project-level artefact, not a per-frame computation."""
    rig, _source = scene_rig()
    rig_path = project / "rig.json"
    rig_path.write_text(json.dumps(rig))

    output = project / "frame.png"
    result = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(output),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert result["success"], result.get("error")
    patch = project / PATCH_FILENAME
    assert patch.exists()
    assert result["patch"] == str(patch)

    meta = read_patch_meta(patch)
    assert meta is not None
    assert meta["fingerprint"] == patch_fingerprint(
        rig, load_layer(project / "character.png"), load_layer(project / PLATE_FILENAME)
    )
    assert meta["fade"] == FADE

    # A later render reads the file rather than rebuilding it.
    mtime = patch.stat().st_mtime_ns
    again = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame2.png"),
        rig=str(rig_path),
        start_frame=FRAMES - 1,
        end_frame=FRAMES - 1,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert again["success"], again.get("error")
    assert again["patch"] == str(patch)
    assert patch.stat().st_mtime_ns == mtime


def test_the_reuse_mode_never_builds_the_patch(project: Path):
    """A caller that must not pay for the region sweep gets no patch."""
    rig, _source = scene_rig()
    rig_path = project / "rig.json"
    rig_path.write_text(json.dumps(rig))

    result = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame.png"),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
        patch="reuse",
    )

    assert result["success"], result.get("error")
    assert "patch" not in result
    assert not (project / PATCH_FILENAME).exists()


def test_the_reuse_mode_uses_the_materialised_patch(project: Path):
    """The materialised patch is used as it is, and never rebuilt."""
    rig, _source = scene_rig()
    rig_path = project / "rig.json"
    rig_path.write_text(json.dumps(rig))

    built = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame.png"),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert built["success"], built.get("error")
    patch = project / PATCH_FILENAME
    mtime = patch.stat().st_mtime_ns

    reused = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame2.png"),
        rig=str(rig_path),
        start_frame=FRAMES - 1,
        end_frame=FRAMES - 1,
        fps=12.0,
        iterations=6,
        still=True,
        patch="reuse",
    )

    assert reused["success"], reused.get("error")
    assert reused["patch"] == str(patch)
    assert patch.stat().st_mtime_ns == mtime


def test_the_reuse_mode_refuses_a_patch_built_for_another_rig(project: Path):
    """The sidecar's fingerprint decides: a stale patch is never composited."""
    rig, _source = scene_rig()
    rig_path = project / "rig.json"
    rig_path.write_text(json.dumps(rig))

    built = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame.png"),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert built["success"], built.get("error")
    patch = project / PATCH_FILENAME
    assert patch.exists()
    mtime = patch.stat().st_mtime_ns

    # The rig moves, so the materialised patch no longer describes it.
    moved = json.loads(rig_path.read_text())
    moved["keyframes"][-1]["pose"]["b0"]["tx"] = SHIFT * 2
    rig_path.write_text(json.dumps(moved))

    reused = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame2.png"),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
        patch="reuse",
    )

    assert reused["success"], reused.get("error")
    assert "patch" not in reused
    # And the stale patch was neither composited nor rebuilt.
    assert patch.stat().st_mtime_ns == mtime


def test_the_patch_is_rebuilt_when_the_rig_it_came_from_changes(project: Path):
    """A rig that moved is a different region, so the patch is rebuilt."""
    rig, _source = scene_rig()
    rig_path = project / "rig.json"
    rig_path.write_text(json.dumps(rig))

    deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame.png"),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
    )
    patch = project / PATCH_FILENAME
    first = patch.stat().st_mtime_ns

    moved = json.loads(rig_path.read_text())
    moved["keyframes"][-1]["pose"]["b0"]["tx"] = SHIFT * 2
    rig_path.write_text(json.dumps(moved))

    result = deform_video(
        input_path=str(project / "source.png"),
        output_path=str(project / "frame2.png"),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert result["success"], result.get("error")
    assert result["patch"] == str(patch)
    assert patch.stat().st_mtime_ns != first
    assert read_patch_meta(patch)["fingerprint"] == patch_fingerprint(
        moved,
        load_layer(project / "character.png"),
        load_layer(project / PLATE_FILENAME),
    )


def test_removing_the_background_layer_keeps_the_character_transparent(project: Path):
    """The patch heals against the plate, so a character-only render is untouched."""
    rig, _source = scene_rig()
    rig["layers"]["background"] = False

    image = render(project, rig, FRAMES - 1, "char_only")
    assert (image[: CHARACTER_ROWS.start, :, 3] == 0).all()
    # The character itself is still solid, where it moved to.
    moved = image[CHARACTER_ROWS, CHARACTER_COLUMNS.start + SHIFT : CHARACTER_COLUMNS.stop + SHIFT]
    assert (moved[:, :, 3] == 255).all()
    # And there is no patch: with no plate there is no background to heal
    # against, so no patch is materialised at all.
    assert not (project / PATCH_FILENAME).exists()
    assert read_patch_meta(project / PATCH_FILENAME) is None


def test_replacing_the_plate_rebuilds_the_patch(project: Path):
    """
    The patch is built from the plate, so a new plate is a new patch.

    The Layers panel's "Change" action on the background layer writes a new
    plate; the materialised patch still holds the old plate's material, so it
    has to be rebuilt rather than reused.
    """
    rig, _source = scene_rig()
    render(project, rig, 0, "replaced")

    patch = project / PATCH_FILENAME
    assert patch.exists()

    # The user replaces the background layer by hand.
    plate = np.zeros((SIZE, SIZE, 4), np.uint8)
    plate[:, :, 0] = 200  # a blue plate, nothing like the still's green band
    plate[:, :, 3] = 255
    assert cv2.imwrite(str(project / PLATE_FILENAME), plate)

    render(project, rig, 0, "replaced")

    # The patch now carries the new plate's material, not the old one's.
    materialised = cv2.imread(str(patch), cv2.IMREAD_UNCHANGED)
    covered = materialised[:, :, 3] > 0
    assert covered.any()
    assert materialised[:, :, 1][covered].max() < 30  # the old plate's green


def test_the_region_covers_the_whole_swept_path():
    """
    The region is the union of the footprints over the *whole* timeline.

    A character that moves almost its own width in a frame leaves a hole in
    the region if the timeline is sampled with a stride - and the character
    would slide from the reconstructed material onto the untouched background.
    """
    rig, source = fast_scene()
    alpha = scene_alpha(source)
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)

    region = character_region(rig, alpha, weights=weights)

    # The whole corridor the character travels through is covered.
    assert (region[22, 16:56] > 0).all()
    # And the region stops exactly where the character stops: the swept area,
    # with no margin around it.
    assert not (region[22, 56:] > 0).any()


def test_the_rest_footprint_keeps_the_plates_own_reconstruction():
    """
    The ground the character stood on is the plate's, not a second inpaint.

    The region is the swept area grown outwards, minus the rest footprint, so
    the patch leaves the rest footprint exactly as the plate reconstructed it.
    """
    rig, source = scene_rig()
    alpha = scene_alpha(source)
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)
    _character, plate = split_layers(source, alpha)

    patch = build_patch(rig, alpha, plate, fade=FADE, weights=weights)

    rest = alpha > 127
    assert rest.any()
    assert np.array_equal(patch[:, :, :3][rest], plate[:, :, :3][rest])


def test_the_renderer_composites_character_over_patch_over_plate():
    """
    The stack order is the one the editor's preview has to match.

    A synthetic patch makes the order observable: a half-transparent green
    layer between the character and the plate tints the background green,
    while the same layer over the plate would tint the character instead.
    """
    rig, source = scene_rig()
    alpha = scene_alpha(source)
    character, _plate = split_layers(source, alpha)

    patch = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    patch[:, :, 1] = 255
    patch[:, :, 3] = 128

    renderer = DeformRenderer(rig, source, iterations=6, character=character, patch=patch)
    frame = renderer.render(FRAMES - 1)

    # The frame is the character over the patch over the plate.
    assert (frame[:, :, 3] == 255).all()

    # The patch is in the middle: the background under it is tinted, and the
    # character over it is not.
    background = frame[:20]
    assert (background[:, :, 1] > background[:, :, 0]).all()
    character_pixels = frame[CHARACTER_ROWS, 26:34]
    assert (character_pixels[:, :, 2] > character_pixels[:, :, 1]).all()
    assert (character_pixels[:, :, 1] == 0).all()
