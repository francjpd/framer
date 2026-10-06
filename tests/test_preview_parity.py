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

from core.deform import DeformRenderer, compute_dense_weights  # noqa: E402
from tests.deform_scene import GOLDEN_FRAME, build_scene  # noqa: E402

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
    )
    assert completed.returncode == 0, f"node preview failed:\n{completed.stderr}"

    rgba = np.frombuffer(output_path.read_bytes(), dtype=np.uint8).reshape(height, width, 4)
    weights = np.frombuffer(weights_path.read_bytes(), dtype=np.float32).reshape(
        len(rig["bones"]), height, width
    )
    return rgba, weights


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


def test_preview_actually_deforms_and_preserves_alpha(tmp_path):
    rig, source = build_scene()

    bind, _ = _render_preview(tmp_path, rig, source, 0, 8)
    posed, _ = _render_preview(tmp_path, rig, source, GOLDEN_FRAME, 8)

    assert not np.array_equal(bind, posed)
    assert posed[:, :, 3].max() == 255
    assert posed[:, :, 3].min() == 0
