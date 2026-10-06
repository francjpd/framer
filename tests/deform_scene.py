"""
Deterministic rig/source used by the deform golden-image test.

Kept in its own import-light module so both the test and
``tests/generate_deform_golden.py`` build byte-for-byte the same scene.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from core.deform import DeformRenderer, validate_rig

GOLDEN_PATH = Path(__file__).parent / "golden" / "deform_frame_08.png"
GOLDEN_FRAME = 8


def build_scene() -> tuple[dict, np.ndarray]:
    """Return the deterministic ``(rig, source)`` used by the golden test."""
    size = 48
    source = np.zeros((size, size, 4), dtype=np.uint8)

    # A textured disc plus a square so weights/rotation are visible, not flat.
    yy, xx = np.mgrid[0:size, 0:size]
    disc = (xx - 24) ** 2 + (yy - 24) ** 2 <= 13**2
    source[disc] = [40, 120, 200, 255]
    source[disc & (((xx + yy) % 6) < 3)] = [80, 180, 30, 255]
    source[6:16, 30:40] = [200, 200, 40, 255]

    rig = {
        "schema": "framer.rig",
        "version": 1,
        "canvas": {"width": size, "height": size},
        "bones": [
            {
                "id": "b0",
                "name": "root",
                "parent": None,
                "rest": {"head": [14, 34], "tail": [14, 14]},
                "radius": 30,
                "falloff": "smooth",
            },
            {
                "id": "b1",
                "name": "arm",
                "parent": "b0",
                "rest": {"head": [14, 14], "tail": [34, 14]},
                "radius": 24,
                "falloff": "smooth",
            },
        ],
        "bind": {"power": 2.0, "radius_scale": 1.0},
        "keyframes": [
            {"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}, "b1": {"rot": 0.0}}},
            {"frame": 8, "pose": {"b0": {"rot": 0.35, "tx": 0, "ty": 0}, "b1": {"rot": -0.5}}},
        ],
        "duration": {"fps": 8, "frames": 9},
    }
    validate_rig(rig)
    return rig, source


def render_golden_frame(frame: int = GOLDEN_FRAME) -> np.ndarray:
    rig, source = build_scene()
    renderer = DeformRenderer(rig, source, iterations=8)
    return renderer.render(frame)
