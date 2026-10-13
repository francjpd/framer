"""
Deterministic rig/source for the layered-deform tests.

Kept in its own module so the engine proof (`tests/test_layered_deform.py`) and
the browser/parity checks build byte-for-byte the same scene.

The scene is deliberately keyable: a near-flat green background with a tight
three-step band so a *resample* would show up as an interpolated green value
(which a perfectly flat colour could hide), and a solid red character block far
from the frame edges so the region it vacates is easy to isolate.
"""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np

from core.deform import validate_rig

SIZE = 64
FRAMES = 12
SHIFT = 14

# Rows no part of the character ever reaches, so they are pure background in
# every frame of the animation.
BACKGROUND_ROWS = slice(0, 30)
# The character's rest rectangle and the rows it occupies while posed.
CHARACTER_ROWS = slice(32, 48)
CHARACTER_COLUMNS = slice(8, 24)


def build_scene() -> tuple[dict, np.ndarray]:
    """Return the deterministic ``(rig, source)`` used by the layered tests."""
    size = SIZE
    source = np.zeros((size, size, 4), dtype=np.uint8)

    band = 190 + (np.arange(size) % 3)
    source[:, :, 0] = 0
    source[:, :, 1] = band[None, :]
    source[:, :, 2] = 0
    source[:, :, 3] = 255

    source[CHARACTER_ROWS, CHARACTER_COLUMNS] = (0, 0, 255, 255)  # BGR red block

    rig = {
        "schema": "framer.rig",
        "version": 1,
        "id": "layered-scene",
        "name": "Layered scene",
        "canvas": {"width": size, "height": size},
        "source": {"kind": "image", "path": "source.png", "frame": 0},
        "duration": {"fps": 12, "frames": FRAMES},
        "mesh": {"mode": "grid", "vertices": [], "triangles": [], "weights": []},
        "bones": [
            {
                "id": "b0",
                "name": "spine",
                "parent": None,
                "rest": {"head": [16, 48], "tail": [16, 32]},
                "radius": size,
                "falloff": "smooth",
            }
        ],
        "bind": {"mode": "auto", "power": 2.0, "radius_scale": 1.0},
        "keyframes": [
            {"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}}},
            {"frame": FRAMES - 1, "pose": {"b0": {"rot": 0.0, "tx": SHIFT, "ty": 0}}},
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


def splitless_scene() -> tuple[dict, np.ndarray]:
    """The same scene as one legacy unsplit document, for contrast."""
    rig, source = build_scene()
    return {key: value for key, value in rig.items() if key != "layers"}, source


def background_block(frame: np.ndarray) -> np.ndarray:
    """The background region of a rendered frame."""
    return frame[BACKGROUND_ROWS]


def character_block(frame: np.ndarray) -> np.ndarray:
    """The character's rest rectangle of a rendered frame."""
    return frame[CHARACTER_ROWS, CHARACTER_COLUMNS]


def vacated_mask(source: np.ndarray, posed: np.ndarray) -> np.ndarray:
    """
    Pixels the character occupied at rest that it no longer covers once posed.

    The character's old footprint minus what the posed cut-out still fills is
    exactly the region the background plate has to cover: it must show the
    reconstructed background, opaque, and none of the character's own pixels.
    """
    was_character = source[CHARACTER_ROWS, CHARACTER_COLUMNS, 2] > 200
    still_character = posed[CHARACTER_ROWS, CHARACTER_COLUMNS, 2] > 200
    return was_character & ~still_character


def write_scene(directory: Path) -> tuple[Path, Path]:
    """Write ``source.png`` and ``rig.json`` into ``directory`` and return them."""
    directory.mkdir(parents=True, exist_ok=True)
    rig, source = build_scene()
    source_path = directory / "source.png"
    rig_path = directory / "rig.json"
    if not cv2.imwrite(str(source_path), source):
        raise RuntimeError(f"could not write {source_path}")
    rig_path.write_text(json.dumps(rig, indent=2))
    return source_path, rig_path
