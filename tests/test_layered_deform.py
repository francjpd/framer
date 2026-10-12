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

Four things are pinned:

1. **The background is unchanged.** The background pixels are byte-identical
   between the rest frame and the frame with the bone moved, and identical to
   the source's own pixels - so the background was never resampled at all.
2. **The contrast is load-bearing.** The same scene rendered as a single layer
   *does* move those pixels, because the bone's influence reaches the whole
   still. That is the behaviour the capability exists to opt out of.
3. **The character still animates.** The character layer really moved, so the
   rig did not simply stop deforming anything.
4. **The vacated region is transparent.** Where the character used to be, the
   render shows none of the character's original pixels.
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

from core.deform import DeformRenderer
from core.layers import LAYER_FILENAME
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
    assert character_block(moved)[:, SHIFT:, 2].max() == 255


def test_the_vacated_region_shows_no_character_pixels(scene):
    directory = scene["dir"]
    source = cv2.imread(str(scene["source_path"]), cv2.IMREAD_UNCHANGED)

    render(directory, "rig.json", 0, "split")
    moved, _ = render(directory, "rig.json", FRAMES - 1, "split")

    vacated = vacated_mask(source, moved)
    assert vacated.any(), "the scene must produce a region the character left"

    vacated_block = moved[CHARACTER_ROWS, CHARACTER_COLUMNS][vacated]
    assert (vacated_block[:, 3] == 0).all()
    assert not vacated_block[:, :3].any()


def test_the_character_layer_is_materialised_once_beside_the_still(scene):
    directory = scene["dir"]
    layer = directory / LAYER_FILENAME

    _rest, first = render(directory, "rig.json", 0, "split")
    assert layer.exists()
    assert first["character"] == str(layer)

    # A later render reads the file rather than recomputing and rewriting it.
    mtime = layer.stat().st_mtime_ns
    _moved, last = render(directory, "rig.json", FRAMES - 1, "split")
    assert "character" not in last
    assert layer.stat().st_mtime_ns == mtime


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
    from core.bg_removal import character_alpha
    from core.layers import split_layers

    character, _background = split_layers(
        source, character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    )
    renderer = DeformRenderer(rig, source, iterations=6, character=character)

    assert renderer.background is not None
    assert (renderer.background[0:30, :, 3] == 255).all()  # background stays opaque
    assert (renderer.background[32:48, 8:24, 3] == 0).all()  # character punched out

    posed = renderer.render(FRAMES - 1)
    # The background region of the output is the still's own, unwarped.
    assert np.array_equal(posed[0:30], source[0:30])
    # ...and it differs from the unsplit render of the same document.
    unsplit = DeformRenderer(splitless_scene()[0], source, iterations=6).render(FRAMES - 1)
    assert not np.array_equal(posed, unsplit)


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
