"""
Proof: moving a bone leaves the background untouched while the character warps.

The layer split is a new editing capability: a rig document may declare
`layers.split`, and from then on the rig deforms the character layer only while
the background layer stays unwarped. Without it, a bone's reach covers whatever
is in the still - which is the documented behaviour of the influence weighting,
not a defect.

This drives the real engine operation (`ops.deform.deform_video`, the same code
the editor's "Render frame" action runs through the Port contract) over the
deterministic scene from `tests/layer_scene.py`, so what it asserts is what an
end user sees.

Five things are pinned:

1. **The background is unchanged.** The background pixels are byte-identical
   between the rest frame and the frame with the bone moved, and identical to
   the source's own pixels - so the background was never resampled at all.
2. **The contrast is load-bearing.** The same scene rendered as a single layer
   *does* move those pixels, because the bone's influence reaches the whole
   still. That is the behaviour the capability exists to opt out of.
3. **The character still animates.** The character layer really moved, so the
   rig did not simply stop deforming anything.
4. **The vacated region shows the reconstructed plate.** Where the character
   used to be, the render is opaque and carries the reconstructed background -
   never a see-through hole and never the character's original pixels.
5. **The character wins over the background.** Where the character moves onto
   background it did not occupy at rest, both layers are opaque, and the
   character is rendered solid rather than blended with the background.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.bg_removal import character_alpha
from core.deform import DeformRenderer
from core.layers import LAYER_FILENAME, PLATE_FILENAME, layer_settings, split_layers
from ops.deform import deform_video
from tests.layer_scene import (
    FRAMES,
    SHIFT,
    SIZE,
    background_block,
    build_scene,
    character_block,
    splitless_scene,
    vacated_mask,
    write_scene,
)

CHARACTER_ROWS = slice(32, 48)
CHARACTER_COLUMNS = slice(8, 24)


def render(directory: Path, rig_name: str, frame: int, tag: str):
    output = directory / f"{tag}_{frame}.png"
    result = deform_video(
        input_path=str(directory / "source.png"),
        output_path=str(output),
        rig=str(directory / rig_name),
        start_frame=frame,
        end_frame=frame,
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert result["success"], result.get("error")
    image = cv2.imread(str(output), cv2.IMREAD_UNCHANGED)
    assert image is not None
    return image, result


@pytest.fixture
def scene(tmp_path: Path):
    source_path, _rig_path = write_scene(tmp_path)
    rig, source = build_scene()

    # The unsplit twin lives beside it so the contrast can be asserted too.
    legacy_rig, _ = splitless_scene()
    (tmp_path / "legacy.json").write_text(json.dumps(legacy_rig))

    return {"dir": tmp_path, "source_path": source_path, "rig": rig, "source": source}


def test_moving_a_bone_leaves_the_background_pixels_unchanged(scene):
    directory = scene["dir"]
    source = cv2.imread(str(scene["source_path"]), cv2.IMREAD_UNCHANGED)

    rest, _ = render(directory, "rig.json", 0, "split")
    moved, _ = render(directory, "rig.json", FRAMES - 1, "split")

    # Identical between the two frames, and identical to the source: the
    # background layer is passed through, never resampled.
    assert np.array_equal(background_block(rest), background_block(moved))
    assert np.array_equal(background_block(moved), background_block(source))


def test_the_same_scene_without_the_split_warps_the_background(scene):
    directory = scene["dir"]

    legacy_rest, _ = render(directory, "legacy.json", 0, "legacy")
    legacy_moved, _ = render(directory, "legacy.json", FRAMES - 1, "legacy")

    # A single-layer still: the bone's influence reaches the whole picture, so
    # the background moves with the character. This is the before-state of the
    # capability, and it is what makes the assertions above meaningful.
    assert not np.array_equal(background_block(legacy_rest), background_block(legacy_moved))


def test_the_character_layer_still_warps(scene):
    directory = scene["dir"]

    rest, _ = render(directory, "rig.json", 0, "split")
    moved, _ = render(directory, "rig.json", FRAMES - 1, "split")

    assert not np.array_equal(character_block(rest), character_block(moved))
    # The cut-out moved right by exactly the keyframed shift, so the character's
    # leading edge now sits where the background used to be.
    leading = moved[CHARACTER_ROWS, CHARACTER_COLUMNS.stop : CHARACTER_COLUMNS.stop + SHIFT]
    assert (leading[:, :, 2] == 255).all()
    assert not leading[:, :, 1].any()


def test_the_vacated_region_shows_the_reconstructed_plate(scene):
    directory = scene["dir"]
    source = cv2.imread(str(scene["source_path"]), cv2.IMREAD_UNCHANGED)

    render(directory, "rig.json", 0, "split")
    moved, _ = render(directory, "rig.json", FRAMES - 1, "split")

    vacated = vacated_mask(source, moved)
    assert vacated.any(), "the scene must produce a region the character left"

    vacated_block = moved[CHARACTER_ROWS, CHARACTER_COLUMNS][vacated]
    # Opaque: the vacated region is the plate, never a see-through hole.
    assert (vacated_block[:, 3] == 255).all()
    # No character colour survives where it moved away...
    assert not vacated_block[:, 2].any()
    # ...and the reconstruction is the still's own background, which the scene's
    # three-step green band pins to a couple of levels.
    green = vacated_block[:, 1]
    assert (green >= 185).all() and (green <= 198).all()


def test_the_character_wins_over_background_it_did_not_occupy(scene):
    directory = scene["dir"]

    render(directory, "rig.json", 0, "split")
    moved, _ = render(directory, "rig.json", FRAMES - 1, "split")

    # The columns the character moves onto were pure background at rest, so both
    # layers are opaque there: the character must render solid, not as a blend
    # with the background behind it.
    occupied = moved[CHARACTER_ROWS, CHARACTER_COLUMNS.stop : CHARACTER_COLUMNS.stop + SHIFT]
    assert (occupied[:, :, 2] == 255).all()
    assert not occupied[:, :, 1].any()
    assert (occupied[:, :, 3] == 255).all()


def test_the_character_layer_is_materialised_once_beside_the_still(scene):
    directory = scene["dir"]
    layer = directory / LAYER_FILENAME
    plate = directory / PLATE_FILENAME

    _rest, first = render(directory, "rig.json", 0, "split")
    assert layer.exists()
    assert first["character"] == str(layer)
    assert plate.exists()

    # A later render reads the files rather than recomputing and rewriting them.
    layer_mtime = layer.stat().st_mtime_ns
    plate_mtime = plate.stat().st_mtime_ns
    _moved, last = render(directory, "rig.json", FRAMES - 1, "split")
    assert "character" not in last
    assert layer.stat().st_mtime_ns == layer_mtime
    assert plate.stat().st_mtime_ns == plate_mtime


def test_the_materialised_layer_is_the_source_with_the_mask_as_alpha(scene):
    directory = scene["dir"]
    source = cv2.imread(str(scene["source_path"]), cv2.IMREAD_UNCHANGED)

    render(directory, "rig.json", 0, "split")
    layer = cv2.imread(str(directory / LAYER_FILENAME), cv2.IMREAD_UNCHANGED)

    assert layer.shape == source.shape
    # Colour is the still's own; alpha is the character mask and nothing else.
    assert np.array_equal(layer[:, :, :3], source[:, :, :3])
    expected_mask = (source[:, :, 2] > 200).astype(np.uint8) * 255
    assert np.array_equal(layer[:, :, 3], expected_mask)


def test_the_recorded_split_mask_is_exact():
    """
    The editor records an exact mask, so no background is warped with the
    character and no character rim is left behind in the plate.

    `layer_settings` over a bare split document is what `Rig.enable_split`
    writes, feathering and cleanup included - or rather, does not.
    """
    _rig, source = build_scene()

    settings = layer_settings({"layers": {"split": True}})
    assert settings["edge_cleanup"] == 0
    assert settings["soft_edges"] == 0

    alpha = character_alpha(source, **settings)
    assert set(np.unique(alpha)) <= {0, 255}

    # Exactly the character's rectangle: no eroded rim inside it, no dilated
    # ring of background around it for the bone to resample.
    assert (alpha[: CHARACTER_ROWS.start] == 0).all()
    assert (alpha[CHARACTER_ROWS.stop :] == 0).all()
    assert (alpha[:, : CHARACTER_COLUMNS.start] == 0).all()
    assert (alpha[:, CHARACTER_COLUMNS.stop :] == 0).all()

    character, plate = split_layers(source, alpha)
    # The character layer carries no background pixel...
    assert (character[:, :, 3][alpha == 0] == 0).all()
    # ...and the plate keeps none of the character's own pixels.
    footprint = plate[CHARACTER_ROWS, CHARACTER_COLUMNS]
    assert not footprint[:, :, 2].any()


def test_a_single_layer_rig_deforms_the_whole_still():
    """The unsplit document keeps the influence over the whole picture."""
    legacy_rig, legacy_source = splitless_scene()

    renderer = DeformRenderer(legacy_rig, legacy_source, iterations=6)
    assert renderer.character is None
    assert renderer.background is None

    # Every frame deforms the one still, exactly as before the split existed.
    assert np.array_equal(renderer.render(0), legacy_source)
    assert renderer.render(FRAMES - 1).shape == legacy_source.shape
    assert not np.array_equal(renderer.render(FRAMES - 1), legacy_source)


def test_the_renderer_deforms_only_the_character_layer(scene):
    rig, source = scene["rig"], scene["source"]

    character, _plate = split_layers(
        source, character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    )
    renderer = DeformRenderer(rig, source, iterations=6, character=character)

    # The background layer is an opaque plate: every pixel is covered, including
    # the character's rest footprint.
    assert renderer.background is not None
    assert (renderer.background[:, :, 3] == 255).all()
    assert not renderer.background[32:48, 8:24, 2].any()

    posed = renderer.render(FRAMES - 1)
    # The background region of the output is the still's own, unwarped.
    assert np.array_equal(posed[0:30], source[0:30])
    # ...and it differs from the unsplit render of the same document.
    unsplit = DeformRenderer(splitless_scene()[0], source, iterations=6).render(FRAMES - 1)
    assert not np.array_equal(posed, unsplit)
    # Every frame is opaque, so the vacated region never encodes as a hole.
    assert (posed[:, :, 3] == 255).all()


def test_a_video_export_keeps_the_background_stable(tmp_path):
    """
    The export path composites the same layers as the single-frame render.

    A WebM/VP9 encode is lossy (and chroma-subsampled), so this cannot assert
    byte equality the way the PNG render does. It asserts the thing that
    matters instead: across the animation the background region of the *split*
    export stays put, while the same scene exported without the split drifts.
    """
    ffmpeg = shutil.which("ffmpeg") or pytest.fail("ffmpeg is required for the export proof")
    write_scene(tmp_path)

    legacy_rig, _ = splitless_scene()
    (tmp_path / "legacy.json").write_text(json.dumps(legacy_rig))

    def export(rig_name: str, output: Path) -> None:
        result = deform_video(
            input_path=str(tmp_path / "source.png"),
            output_path=str(output),
            rig=str(tmp_path / rig_name),
            fps=12.0,
            iterations=6,
            still=True,
        )
        assert result["success"], result.get("error")

    def background_drift(output: Path) -> float:
        decode = _frame_decoder(ffmpeg, output)
        first = background_block(decode(0))
        last = background_block(decode(FRAMES - 1))
        return float(np.abs(first.astype(np.int16) - last.astype(np.int16)).mean())

    split_export = tmp_path / "split.webm"
    legacy_export = tmp_path / "legacy.webm"
    export("rig.json", split_export)
    export("legacy.json", legacy_export)

    split_drift = background_drift(split_export)
    legacy_drift = background_drift(legacy_export)

    # The split export's background only moves by encoder noise; the unsplit one
    # is visibly warped by the bone.
    assert split_drift <= 1.0, f"split export background drifted by {split_drift:.2f}"
    assert legacy_drift > 10.0, f"unsplit export background drifted by only {legacy_drift:.2f}"


def test_a_split_rig_exports_to_mp4_with_the_plate_in_the_vacated_region(tmp_path):
    """
    MP4 drops alpha, so the guard has to look at what is actually encoded.

    A split rig composites over an opaque plate, so its frames are opaque and
    the export succeeds - and the region the character vacated encodes as the
    reconstructed background rather than as a flattened black hole.
    """
    ffmpeg = shutil.which("ffmpeg") or pytest.fail("ffmpeg is required for the export proof")
    write_scene(tmp_path)

    result = deform_video(
        input_path=str(tmp_path / "source.png"),
        output_path=str(tmp_path / "split.mp4"),
        rig=str(tmp_path / "rig.json"),
        fps=12.0,
        iterations=6,
        still=True,
    )
    assert result["success"], result.get("error")

    source = cv2.imread(str(tmp_path / "source.png"), cv2.IMREAD_UNCHANGED)
    last = _yuv420p_frame(ffmpeg, tmp_path / "split.mp4", FRAMES - 1)

    vacated = vacated_mask(source, last)
    assert vacated.any(), "the scene must produce a region the character left"

    vacated_block = last[CHARACTER_ROWS, CHARACTER_COLUMNS][vacated]
    # Opaque green background, not the black an uncovered hole would encode to.
    assert (vacated_block[:, 1] > vacated_block[:, 0]).all()
    assert (vacated_block[:, 1] > vacated_block[:, 2]).all()
    assert (vacated_block[:, 1] > 100).all()


def test_mp4_export_rejects_transparency_in_frame(tmp_path):
    source = np.zeros((32, 32, 4), dtype=np.uint8)
    source_path = tmp_path / "transparent.png"
    cv2.imwrite(str(source_path), source)
    legacy_rig, _ = splitless_scene()
    rig_path = tmp_path / "rig.json"
    rig_path.write_text(json.dumps(legacy_rig))

    result = deform_video(
        input_path=str(source_path),
        output_path=str(tmp_path / "transparent.mp4"),
        rig=str(rig_path),
        fps=12.0,
        iterations=1,
        still=True,
    )
    assert not result["success"]
    assert "MP4 does not support alpha" in result["error"]
    assert not (tmp_path / "transparent.mp4").exists()


def _yuv420p_frame(ffmpeg: str, path: Path, frame: int) -> np.ndarray:
    """Decode one frame of an alpha-dropping (yuv420p) encode back to BGRA."""
    raw = subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            str(path),
            "-vf",
            f"select=eq(n\\,{frame})",
            "-frames:v",
            "1",
            "-pix_fmt",
            "bgra",
            "-f",
            "rawvideo",
            "-",
        ],
        capture_output=True,
        check=True,
    ).stdout
    assert len(raw) == SIZE * SIZE * 4
    return np.frombuffer(raw, dtype=np.uint8).reshape(SIZE, SIZE, 4)


def _frame_decoder(ffmpeg: str, path: Path):
    def decode(frame: int) -> np.ndarray:
        raw = subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-c:v",
                "libvpx-vp9",
                "-i",
                str(path),
                "-vf",
                f"select=eq(n\\,{frame})",
                "-frames:v",
                "1",
                "-pix_fmt",
                "bgra",
                "-f",
                "rawvideo",
                "-",
            ],
            capture_output=True,
            check=True,
        ).stdout
        assert len(raw) == SIZE * SIZE * 4
        return np.frombuffer(raw, dtype=np.uint8).reshape(SIZE, SIZE, 4)

    return decode


def test_remove_the_background_leaves_character_alone_with_transparency(scene):
    """
    Removing the background layer leaves only the character layer.
    The rendered frame outside the character area is transparent (alpha = 0).
    """
    rig, source = scene["rig"], scene["source"]
    no_bg_rig = json.loads(json.dumps(rig))
    no_bg_rig["layers"]["background"] = False

    character, _plate = split_layers(
        source, character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    )
    renderer = DeformRenderer(no_bg_rig, source, iterations=6, character=character)

    assert renderer.background is None
    assert renderer.character is not None

    rest = renderer.render(0)
    # Outside the character block (e.g. top rows), alpha is transparent (0)
    assert (rest[: CHARACTER_ROWS.start, :, 3] == 0).all()
    # Inside the character block, alpha is opaque (255)
    assert (rest[CHARACTER_ROWS, CHARACTER_COLUMNS, 3] == 255).all()

    posed = renderer.render(FRAMES - 1)
    # The deformed character is also transparent outside the warped character
    assert (posed[0:4, :, 3] == 0).all()
