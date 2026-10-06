"""
Golden-image test for the deform engine.

A small deterministic rig (two chained bones posing a textured still) is
rendered at a fixed frame and compared against a committed golden PNG.  The
comparison is tolerance based so a different OpenCV build cannot fail the
suite on one or two interpolation ULP differences, but a real regression (a
wrong weight, a broken parent transform, a transposed remap) moves far more
than the tolerance.

Regenerate the golden with:

    .venv/bin/python tests/generate_deform_golden.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.deform import DeformRenderer  # noqa: E402
from tests.deform_scene import (  # noqa: E402
    GOLDEN_PATH,
    build_scene,
    render_golden_frame,
)

# Tolerances: the render is deterministic on one OpenCV build; allow a small
# amount of interpolation drift across builds without hiding a real change.
MEAN_TOLERANCE = 2.0
OUTLIER_TOLERANCE = 16
MAX_OUTLIER_FRACTION = 0.02


def test_golden_frame_matches_the_committed_image():
    assert GOLDEN_PATH.exists(), (
        f"missing golden image {GOLDEN_PATH}; regenerate it with "
        "`.venv/bin/python tests/generate_deform_golden.py`"
    )

    golden = cv2.imread(str(GOLDEN_PATH), cv2.IMREAD_UNCHANGED)
    assert golden is not None, f"could not decode golden image {GOLDEN_PATH}"

    rendered = render_golden_frame()

    assert rendered.shape == golden.shape

    diff = np.abs(rendered.astype(np.int16) - golden.astype(np.int16))
    mean_diff = float(diff.mean())
    outlier_fraction = float((diff > OUTLIER_TOLERANCE).mean())

    assert mean_diff <= MEAN_TOLERANCE, f"mean pixel difference {mean_diff:.3f} too large"
    assert outlier_fraction <= MAX_OUTLIER_FRACTION, (
        f"{outlier_fraction:.4f} of pixels differ by more than {OUTLIER_TOLERANCE}"
    )


def test_golden_scene_is_actually_deformed():
    """Guard against a golden that was generated from an identity render."""
    rig, source = build_scene()
    renderer = DeformRenderer(rig, source, iterations=8)

    identity = renderer.render(0)
    deformed = renderer.render(8)

    assert not np.array_equal(identity, deformed)
    # The bind pose must still be the identity transform.
    assert np.array_equal(identity, source)


def test_golden_frame_preserves_the_alpha_plane():
    golden = cv2.imread(str(GOLDEN_PATH), cv2.IMREAD_UNCHANGED)
    assert golden is not None
    alpha = golden[:, :, 3]
    assert alpha.max() == 255
    assert alpha.min() == 0
