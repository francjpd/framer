"""
Golden-parity test: the interactive preview math vs the engine's final render.

The editor draws its preview with `framer/apps/framer_web/assets/js/lbs.mjs`,
which re-implements the engine's fixed-point linear blend skinning. This test
keeps the two honest: it renders the deterministic scene from
`tests.deform_scene.py` with the authoritative Python `DeformRenderer`, then
runs the *same* scene through the JavaScript preview under Node and compares
the dense weights and the rendered pixels.

The comparison is tolerance based (the two implementations differ only in
floating point rounding and OpenCV's fixed-point bilinear coefficients), but a
real algorithmic drift - a transposed map, a different falloff, a missing
normalisation - moves far more than the tolerance.

Skipped when Node is unavailable; the Python engine's own golden test
(`tests/test_golden_deform.py`) still covers the authoritative render.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from core.deform import (
    DeformRenderer,
    compute_dense_weights,
    interpolate_keyframes,
)
from tests.deform_scene import GOLDEN_FRAME, build_scene
from tests.layer_scene import (
    FRAMES,
    background_block,
    character_block,
)
from tests.layer_scene import (
    build_scene as build_layered_scene,
)

RUNNER = Path(__file__).parent / "preview_parity_runner.mjs"
NODE = shutil.which("node")

pytestmark = pytest.mark.skipif(NODE is None, reason="node is required for the preview parity test")

WEIGHT_TOLERANCE = 1e-5
MEAN_TOLERANCE = 2.0
OUTLIER_TOLERANCE = 24
MAX_OUTLIER_FRACTION = 0.03


def _render_preview(tmp_path: Path, rig: dict, source: np.ndarray, frame: int, iterations: int):
    height, width = source.shape[:2]
    source_path = tmp_path / "source.rgba"
    source_path.write_bytes(source.tobytes())

    output_path = tmp_path / "preview.rgba"
    weights_path = tmp_path / "preview_weights.f32"

    spec = {
        "source": str(source_path),
        "output": str(output_path),
        "weights_output": str(weights_path),
        "width": int(width),
        "height": int(height),
        "rig": rig,
        "frame": int(frame),
        "iterations": int(iterations),
    }
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(spec))

    completed = subprocess.run(
        [NODE, str(RUNNER), str(spec_path)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )
    assert completed.returncode == 0, f"node preview failed:\n{completed.stderr}"

    rgba = np.frombuffer(output_path.read_bytes(), dtype=np.uint8).reshape(height, width, 4)
    weights = np.frombuffer(weights_path.read_bytes(), dtype=np.float32).reshape(
        len(rig["bones"]), height, width
    )
    return rgba, weights


def _render_layered_preview(
    tmp_path: Path,
    rig: dict,
    source: np.ndarray,
    character: np.ndarray,
    plate: np.ndarray | None,
    frame: int,
    iterations: int,
):
    """Render the split scene through the preview, passing the two layers (or character only)."""
    height, width = source.shape[:2]
    source_path = tmp_path / "source.rgba"
    source_path.write_bytes(source.tobytes())
    character_path = tmp_path / "character.rgba"
    character_path.write_bytes(character.tobytes())

    output_path = tmp_path / "preview.rgba"

    spec = {
        "source": str(source_path),
        "character": str(character_path),
        "output": str(output_path),
        "width": int(width),
        "height": int(height),
        "rig": rig,
        "frame": int(frame),
        "iterations": int(iterations),
    }
    if plate is not None:
        plate_path = tmp_path / "background.rgba"
        plate_path.write_bytes(plate.tobytes())
        spec["background"] = str(plate_path)

    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(spec))

    completed = subprocess.run(
        [NODE, str(RUNNER), str(spec_path)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )
    assert completed.returncode == 0, f"node preview failed:\n{completed.stderr}"

    return np.frombuffer(output_path.read_bytes(), dtype=np.uint8).reshape(height, width, 4)


def _interpolated_poses(tmp_path: Path, rig: dict, frames: list[int]) -> dict[str, dict]:
    """Return the `lbs.mjs` interpolated poses (keyed by frame string) via Node."""
    poses_path = tmp_path / "preview_poses.json"

    spec = {"rig": rig, "poses_output": str(poses_path), "poses_frames": list(frames)}
    spec_path = tmp_path / "spec_poses.json"
    spec_path.write_text(json.dumps(spec))

    completed = subprocess.run(
        [NODE, str(RUNNER), str(spec_path)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )
    assert completed.returncode == 0, f"node pose interpolation failed:\n{completed.stderr}"

    return json.loads(poses_path.read_text())


def test_preview_weights_match_the_engine(tmp_path):
    rig, source = build_scene()

    _, preview_weights = _render_preview(tmp_path, rig, source, GOLDEN_FRAME, 8)
    engine_weights = compute_dense_weights(rig)

    assert preview_weights.shape == engine_weights.shape
    assert float(np.abs(preview_weights - engine_weights).max()) <= WEIGHT_TOLERANCE


def test_preview_frame_matches_the_engine(tmp_path):
    rig, source = build_scene()

    preview, _ = _render_preview(tmp_path, rig, source, GOLDEN_FRAME, 8)
    engine = DeformRenderer(rig, source, iterations=8).render(GOLDEN_FRAME)

    assert preview.shape == engine.shape

    diff = np.abs(preview.astype(np.int16) - engine.astype(np.int16))
    mean_diff = float(diff.mean())
    outlier_fraction = float((diff > OUTLIER_TOLERANCE).mean())

    assert mean_diff <= MEAN_TOLERANCE, f"mean pixel difference {mean_diff:.3f} too large"
    assert outlier_fraction <= MAX_OUTLIER_FRACTION, (
        f"{outlier_fraction:.4f} of pixels differ by more than {OUTLIER_TOLERANCE}"
    )


def test_preview_bind_pose_is_the_identity(tmp_path):
    rig, source = build_scene()

    preview, _ = _render_preview(tmp_path, rig, source, 0, 8)

    # At the bind pose every local pose is identity, so the preview must
    # reproduce the source exactly.
    assert np.array_equal(preview, source)


def test_zero_bone_rig_previews_the_source_unchanged(tmp_path):
    # A freshly loaded still has no bones yet, and the preview must show the
    # source unchanged: skinningFields must fall back to the identity field
    # instead of a zero matrix that collapses the whole image onto one pixel.
    # No engine comparison here on purpose: the engine rejects empty bones by
    # design, so the preview alone must reproduce the source exactly.
    size = 32
    source = np.zeros((size, size, 4), dtype=np.uint8)

    # Transparent border with an opaque subject block (same shape as
    # `Fixtures.png_with_subject` in the Elixir suite).
    x0, x1 = size // 4, size - size // 4
    y0, y1 = size // 4, size - size // 4
    source[y0:y1, x0:x1] = [200, 40, 40, 255]

    rig = {
        "schema": "framer.rig",
        "version": 1,
        "canvas": {"width": size, "height": size},
        "bones": [],
        "bind": {"power": 2.0, "radius_scale": 1.0},
        "keyframes": [],
        "duration": {"fps": 8, "frames": 1},
    }

    preview, _ = _render_preview(tmp_path, rig, source, 0, 5)

    assert np.array_equal(preview, source)
    assert preview[:, :, 3].max() == 255


def test_preview_actually_deforms_and_preserves_alpha(tmp_path):
    rig, source = build_scene()

    bind, _ = _render_preview(tmp_path, rig, source, 0, 8)
    posed, _ = _render_preview(tmp_path, rig, source, GOLDEN_FRAME, 8)

    assert not np.array_equal(bind, posed)
    assert posed[:, :, 3].max() == 255
    assert posed[:, :, 3].min() == 0


def test_interpolated_poses_match_the_engine(tmp_path):
    rig, _source = build_scene()

    frames = [0, 2, 4, GOLDEN_FRAME, 20]
    js_poses = _interpolated_poses(tmp_path, rig, frames)

    for frame in frames:
        expected = interpolate_keyframes(rig, frame)
        actual = js_poses[str(frame)]

        assert set(actual) == set(expected)
        for bone_id, pose in expected.items():
            for channel in ("rot", "tx", "ty"):
                assert float(actual[bone_id][channel]) == pytest.approx(pose[channel], abs=1e-6)


# --- layered preview --------------------------------------------------------
#
# A split rig deforms the character layer only. `lbs.mjs` mirrors
# `core/layers.py` (the cut-out, the opaque background plate and the
# source-over composite), so the preview and the export agree on the layering by
# construction - these tests hold both halves of that claim: the preview keeps
# the background put, and the preview's layered render matches the engine's.


def _layered_layers(source: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The engine's own character cut-out and background plate for a still."""
    from core.bg_removal import character_alpha
    from core.layers import split_layers

    return split_layers(source, character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0))


def test_layered_preview_keeps_the_background_put(tmp_path):
    rig, source = build_layered_scene()
    character, plate = _layered_layers(source)

    rest = _render_layered_preview(tmp_path, rig, source, character, plate, 0, 8)
    posed = _render_layered_preview(tmp_path, rig, source, character, plate, FRAMES - 1, 8)

    # The background rows are byte-identical between the rest frame and the
    # posed frame in the browser preview too.
    assert np.array_equal(background_block(rest), background_block(posed))
    # And the character layer really moved, so the claim is not vacuous.
    assert not np.array_equal(character_block(rest), character_block(posed))


def test_layered_preview_matches_the_engine(tmp_path):
    rig, source = build_layered_scene()
    character, plate = _layered_layers(source)

    preview = _render_layered_preview(tmp_path, rig, source, character, plate, FRAMES - 1, 8)
    engine = DeformRenderer(rig, source, iterations=8, character=character).render(FRAMES - 1)

    assert preview.shape == engine.shape

    diff = np.abs(preview.astype(np.int16) - engine.astype(np.int16))
    mean_diff = float(diff.mean())
    outlier_fraction = float((diff > OUTLIER_TOLERANCE).mean())

    assert mean_diff <= MEAN_TOLERANCE, f"mean pixel difference {mean_diff:.3f} too large"
    assert outlier_fraction <= MAX_OUTLIER_FRACTION, (
        f"{outlier_fraction:.4f} of pixels differ by more than {OUTLIER_TOLERANCE}"
    )


def test_character_only_preview_leaves_character_alone_with_transparency(tmp_path):
    rig, source = build_layered_scene()
    rig["layers"]["background"] = False
    character, _plate = _layered_layers(source)

    preview = _render_layered_preview(tmp_path, rig, source, character, None, 0, 8)
    # Outside the character area, alpha is transparent (0)
    assert (preview[:32, :, 3] == 0).all()
    # Inside the character area, alpha is opaque (255)
    assert (preview[32:48, 8:24, 3] == 255).all()


def test_character_only_preview_matches_the_engine(tmp_path):
    rig, source = build_layered_scene()
    rig["layers"]["background"] = False
    character, _plate = _layered_layers(source)

    preview = _render_layered_preview(tmp_path, rig, source, character, None, FRAMES - 1, 8)
    engine = DeformRenderer(rig, source, iterations=8, character=character).render(FRAMES - 1)

    assert preview.shape == engine.shape
    diff = np.abs(preview.astype(np.int16) - engine.astype(np.int16))
    mean_diff = float(diff.mean())
    outlier_fraction = float((diff > OUTLIER_TOLERANCE).mean())

    assert mean_diff <= MEAN_TOLERANCE, f"mean pixel difference {mean_diff:.3f} too large"
    assert outlier_fraction <= MAX_OUTLIER_FRACTION, (
        f"{outlier_fraction:.4f} of pixels differ by more than {OUTLIER_TOLERANCE}"
    )


def test_js_composite_puts_an_opaque_character_over_an_opaque_plate(tmp_path):
    # The core scenario in one pixel: the character has warped over background
    # it did not occupy at rest, so both layers are opaque there. The composite
    # must hand the character through solid rather than blend it 50/50.
    character = np.zeros((2, 2, 4), dtype=np.uint8)
    plate = np.zeros((2, 2, 4), dtype=np.uint8)
    character[:, :, :3] = (255, 0, 0)
    character[:, :, 3] = 255
    plate[:, :, :3] = (0, 190, 0)
    plate[:, :, 3] = 255

    character_path = tmp_path / "character.rgba"
    plate_path = tmp_path / "background.rgba"
    character_path.write_bytes(character.tobytes())
    plate_path.write_bytes(plate.tobytes())

    output_path = tmp_path / "composite.rgba"

    spec = {
        "composite": {"character": str(character_path), "background": str(plate_path)},
        "output": str(output_path),
    }
    spec_path = tmp_path / "spec_composite.json"
    spec_path.write_text(json.dumps(spec))

    completed = subprocess.run(
        [NODE, str(RUNNER), str(spec_path)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )
    assert completed.returncode == 0, f"node composite failed:\n{completed.stderr}"

    out = np.frombuffer(output_path.read_bytes(), dtype=np.uint8).reshape(2, 2, 4)
    assert (out[:, :, 3] == 255).all()
    assert (out[:, :, :3] == (255, 0, 0)).all()
