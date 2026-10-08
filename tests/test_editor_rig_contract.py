"""
Contract test: the editor's rig document is exactly what the engine consumes.

The editor persists a superset of the engine's schema - it adds `id`, `name`,
`source`, `mesh` and `playback` so the UI can reload and preview the rig. The
engine must accept that document unchanged (unknown fields are ignored) and
render it, which is what makes "the versioned rig JSON is the contract" true.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.deform import (
    DeformRenderer,
    build_grid_mesh,
    compute_vertex_weights,
    load_rig,
    validate_rig,
)
from tests.deform_scene import build_scene


def _editor_document() -> dict:
    """A rig as the LiveView editor writes it (extra editor-only fields)."""
    rig, _source = build_scene()
    vertices, triangles = build_grid_mesh(rig)
    weights = compute_vertex_weights(rig, vertices)

    return {
        **rig,
        "id": "editor-rig",
        "name": "Editor rig",
        "source": {"kind": "image", "path": "assets/character.png", "frame": 0},
        "mesh": {
            "mode": "grid",
            "vertices": vertices.tolist(),
            "triangles": triangles.tolist(),
            "weights": weights.tolist(),
        },
        "playback": {"loop": True},
    }


def test_validator_accepts_the_editor_document():
    document = _editor_document()
    assert validate_rig(document) is document


def test_engine_renders_the_editor_document(tmp_path):
    document = _editor_document()
    path = tmp_path / "editor-rig.json"
    path.write_text(__import__("json").dumps(document))

    loaded = load_rig(path)
    assert loaded["mesh"]["vertices"]
    assert loaded["playback"] == {"loop": True}

    _rig, source = build_scene()
    renderer = DeformRenderer(loaded, source, iterations=8)

    bind = renderer.render(0)
    deformed = renderer.render(8)

    assert np.array_equal(bind, source)
    assert not np.array_equal(bind, deformed)
