"""
Unit tests for the deform engine core (`core/deform.py`).

The engine is pure math plus OpenCV sampling, so most tests build tiny
deterministic rigs and assert geometric invariants: weights are normalized,
the bind pose is the identity, a pure translation shifts the image, and a
rotation pins the bone head.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.deform import (
    DeformRenderer,
    RigError,
    apply_lbs,
    bone_local_matrix,
    build_grid_mesh,
    compute_backward_map,
    compute_dense_weights,
    compute_vertex_weights,
    evaluate_bones,
    interpolate_keyframes,
    is_image_path,
    load_or_build_weights,
    load_rig,
    load_source,
    rig_fingerprint,
    validate_rig,
)


def base_rig(**overrides):
    rig = {
        "schema": "framer.rig",
        "version": 1,
        "canvas": {"width": 32, "height": 32},
        "bones": [
            {
                "id": "b0",
                "name": "root",
                "parent": None,
                "rest": {"head": [16, 16], "tail": [16, 4]},
                "radius": 100,
                "falloff": "smooth",
            }
        ],
        "bind": {"power": 2.0, "radius_scale": 1.0},
        "keyframes": [
            {"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}}},
            {"frame": 10, "pose": {"b0": {"rot": 0.0, "tx": 8, "ty": 0}}},
        ],
        "duration": {"fps": 10, "frames": 11},
    }
    rig.update(overrides)
    return rig


def source_image(size=32):
    image = np.zeros((size, size, 4), dtype=np.uint8)
    image[size // 4 : size * 3 // 4, size // 4 : size * 3 // 4] = [0, 0, 255, 255]
    return image


# --- schema / validator -----------------------------------------------------


def test_validate_rig_accepts_a_valid_document():
    rig = base_rig()
    assert validate_rig(rig) is rig


def test_validate_rig_rejects_wrong_schema_and_version():
    with pytest.raises(RigError, match="schema"):
        validate_rig(base_rig(schema="other.rig"))
    with pytest.raises(RigError, match="version"):
        validate_rig(base_rig(version=99))


def test_validate_rig_rejects_bad_canvas_and_bones():
    with pytest.raises(RigError, match="canvas"):
        validate_rig(base_rig(canvas={"width": 0, "height": 32}))

    with pytest.raises(RigError, match="non-empty"):
        validate_rig(base_rig(bones=[]))


def test_validate_rig_rejects_duplicate_and_unknown_parent():
    duplicate = base_rig(
        bones=[
            {"id": "b0", "rest": {"head": [1, 1], "tail": [2, 2]}},
            {"id": "b0", "rest": {"head": [3, 3], "tail": [4, 4]}},
        ]
    )
    with pytest.raises(RigError, match="duplicate"):
        validate_rig(duplicate)

    unknown = base_rig(
        bones=[{"id": "b0", "parent": "ghost", "rest": {"head": [1, 1], "tail": [2, 2]}}]
    )
    with pytest.raises(RigError, match="not a known bone"):
        validate_rig(unknown)


def test_validate_rig_rejects_a_bone_cycle():
    cyclic = base_rig(
        bones=[
            {"id": "a", "parent": "b", "rest": {"head": [1, 1], "tail": [2, 2]}},
            {"id": "b", "parent": "a", "rest": {"head": [3, 3], "tail": [4, 4]}},
        ]
    )
    with pytest.raises(RigError, match="cycle"):
        validate_rig(cyclic)


def test_validate_rig_rejects_unknown_keyframe_bone():
    rig = base_rig(keyframes=[{"frame": 0, "pose": {"ghost": {"rot": 0}}}])
    with pytest.raises(RigError, match="unknown bone"):
        validate_rig(rig)


def test_load_rig_round_trips_and_rejects_missing_files(tmp_path):
    path = tmp_path / "rig.json"
    path.write_text(json.dumps(base_rig()))
    assert load_rig(path)["schema"] == "framer.rig"

    with pytest.raises(RigError, match="not found"):
        load_rig(tmp_path / "missing.json")


# --- weights ----------------------------------------------------------------


def test_dense_weights_are_normalized_and_cover_the_canvas():
    weights = compute_dense_weights(base_rig())
    assert weights.shape == (1, 32, 32)
    assert np.allclose(weights.sum(axis=0), 1.0, atol=1e-5)


def test_dense_weights_fall_back_to_the_nearest_bone_outside_every_radius():
    rig = base_rig(
        bones=[
            {
                "id": "left",
                "rest": {"head": [4, 16], "tail": [4, 16]},
                "radius": 3,
            },
            {
                "id": "right",
                "rest": {"head": [28, 16], "tail": [28, 16]},
                "radius": 3,
            },
        ]
    )
    weights = compute_dense_weights(rig)

    # A far-away pixel has no influence from either radius but must still be
    # weighted, and it must pick the nearer bone.
    assert weights[0, 0, 0] == 1.0
    assert weights[1, 0, 0] == 0.0
    assert np.allclose(weights.sum(axis=0), 1.0, atol=1e-5)


def test_dense_weights_respect_radius_scale():
    bones = [
        {"id": "b0", "rest": {"head": [16, 16], "tail": [16, 16]}, "radius": 2},
        {"id": "b1", "rest": {"head": [8, 16], "tail": [8, 16]}, "radius": 100},
    ]
    tight = compute_dense_weights(base_rig(bones=bones, bind={"power": 2.0, "radius_scale": 1.0}))
    wide = compute_dense_weights(base_rig(bones=bones, bind={"power": 2.0, "radius_scale": 4.0}))

    # A pixel 4px from b0 is outside its 2px radius but inside the 8px scaled
    # radius, so the second rig gives b0 real influence there.
    assert tight[0, 12, 16] == 0.0
    assert wide[0, 12, 16] > 0.0


def test_weights_cache_loads_and_builds(tmp_path):
    rig = base_rig()
    cache = tmp_path / "weights.npz"

    first = load_or_build_weights(rig, cache_path=cache)
    assert cache.exists()

    # Clear the in-process cache so the second call must read the .npz file.
    from core import deform

    deform._WEIGHT_CACHE.clear()

    second = load_or_build_weights(rig, cache_path=cache)
    assert np.allclose(first, second)


def test_rig_fingerprint_changes_when_a_bone_moves():
    assert rig_fingerprint(base_rig()) != rig_fingerprint(
        base_rig(
            bones=[
                {
                    "id": "b0",
                    "rest": {"head": [8, 16], "tail": [8, 4]},
                    "radius": 100,
                }
            ]
        )
    )


# --- mesh -------------------------------------------------------------------


def test_grid_mesh_and_vertex_weights_are_well_formed():
    rig = base_rig()
    vertices, triangles = build_grid_mesh(rig, cell_size=8)

    assert vertices.shape[1] == 2
    assert triangles.shape[1] == 3
    assert triangles.max() < len(vertices)

    vertex_weights = compute_vertex_weights(rig, vertices)
    assert vertex_weights.shape == (len(vertices), 1)
    assert np.allclose(vertex_weights.sum(axis=1), 1.0, atol=1e-5)


# --- keyframes / bones ------------------------------------------------------


def test_interpolate_keyframes_linearly_and_clamps():
    rig = base_rig()

    assert interpolate_keyframes(rig, -5)["b0"]["tx"] == 0.0
    assert interpolate_keyframes(rig, 5)["b0"]["tx"] == pytest.approx(4.0)
    assert interpolate_keyframes(rig, 50)["b0"]["tx"] == 8.0


def test_interpolate_keyframes_defaults_missing_bones_to_identity():
    rig = base_rig(
        bones=[
            {"id": "b0", "rest": {"head": [1, 1], "tail": [2, 2]}},
            {"id": "b1", "parent": "b0", "rest": {"head": [2, 2], "tail": [3, 3]}},
        ],
        keyframes=[{"frame": 0, "pose": {"b0": {"tx": 5}}}],
    )
    poses = interpolate_keyframes(rig, 0)
    assert poses["b1"] == {"rot": 0.0, "tx": 0.0, "ty": 0.0}


def test_bone_local_matrix_rotates_about_the_head():
    head = [10.0, 10.0]
    matrix = bone_local_matrix(head, {"rot": np.pi / 2, "tx": 0.0, "ty": 0.0})
    point = matrix @ np.array([10.0, 0.0, 1.0])
    assert point[0] == pytest.approx(20.0, abs=1e-6)
    assert point[1] == pytest.approx(10.0, abs=1e-6)


def test_evaluate_bones_composes_down_the_parent_chain():
    rig = base_rig(
        bones=[
            {"id": "b0", "rest": {"head": [0, 0], "tail": [10, 0]}},
            {"id": "b1", "parent": "b0", "rest": {"head": [10, 0], "tail": [20, 0]}},
        ],
        keyframes=[{"frame": 0, "pose": {"b0": {"tx": 10.0}}}],
    )
    worlds = evaluate_bones(rig, 0)
    # The child inherits the parent translation.
    child = worlds[1] @ np.array([10.0, 0.0, 1.0])
    assert child[0] == pytest.approx(20.0)
    assert child[1] == pytest.approx(0.0)


# --- rendering --------------------------------------------------------------


def test_identity_pose_is_the_identity_transform():
    rig = base_rig(keyframes=[{"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}}}])
    image = source_image()
    renderer = DeformRenderer(rig, image, iterations=5)

    rendered = renderer.render(0)
    assert np.array_equal(rendered, image)


def test_pure_translation_shifts_the_image():
    rig = base_rig()
    image = source_image()
    renderer = DeformRenderer(rig, image, iterations=8)

    shifted = renderer.render(10)

    # The box originally spans x = 8..23; after +8 it spans x = 16..31.
    assert shifted[16, 20, 3] == 255
    assert shifted[16, 4, 3] == 0
    assert np.array_equal(shifted[:, 16:, :], image[:, 8:24, :][:, :16, :])


def test_rotation_pins_the_bone_head():
    rig = base_rig(
        keyframes=[
            {"frame": 0, "pose": {"b0": {"rot": 0.0}}},
            {"frame": 10, "pose": {"b0": {"rot": np.pi / 2}}},
        ]
    )
    image = source_image()
    renderer = DeformRenderer(rig, image, iterations=8)
    rotated = renderer.render(10)

    # The head (16, 16) is the rotation centre, so it maps to itself.
    assert rotated[16, 16, 3] == 255


def test_apply_lbs_supports_plain_bgr_frames():
    rig = base_rig()
    weights = compute_dense_weights(rig)
    identity = evaluate_bones(rig, 0)
    bgr = source_image()[:, :, :3]

    result = apply_lbs(bgr, weights, identity, identity, iterations=3)
    assert result.shape == bgr.shape
    assert np.array_equal(result, bgr)


def test_compute_backward_map_is_identity_when_the_transform_is_identity():
    matrix = np.tile(np.eye(2, dtype=np.float32), (4, 4, 1, 1))
    translation = np.zeros((4, 4, 2), dtype=np.float32)
    map_x, map_y = compute_backward_map(matrix, translation, iterations=4)
    assert np.allclose(map_x, np.tile(np.arange(4, dtype=np.float32), (4, 1)))
    assert np.allclose(map_y, np.tile(np.arange(4, dtype=np.float32)[:, None], (1, 4)))


def test_deform_renderer_resizes_to_canvas_and_writes_png(tmp_path):
    rig = base_rig(canvas={"width": 16, "height": 16})
    image = source_image(32)  # deliberately larger than the canvas
    renderer = DeformRenderer(rig, image)

    assert renderer.source.shape[:2] == (16, 16)

    output = tmp_path / "frame.png"
    renderer.render_to_png(0, output)
    written = cv2.imread(str(output), cv2.IMREAD_UNCHANGED)
    assert written is not None
    assert written.shape == (16, 16, 4)


def test_renderer_rejects_weights_of_the_wrong_shape():
    rig = base_rig()
    with pytest.raises(RigError, match="weights"):
        DeformRenderer(rig, source_image(), weights=np.zeros((2, 32, 32), dtype=np.float32))


# --- source loading ---------------------------------------------------------


def test_load_source_adds_an_opaque_alpha_plane(tmp_path):
    from tests.conftest import make_still

    path = make_still(tmp_path / "still.png")
    source = load_source(path)
    assert source.shape[2] == 4
    assert source[:, :, 3].max() == 255

    assert is_image_path(path)
    assert not is_image_path("clip.mp4")


def test_load_source_falls_back_to_a_video_first_frame(tmp_path):
    from tests.conftest import make_clip

    clip = make_clip(tmp_path / "clip.mp4")
    source = load_source(clip)
    assert source.shape[2] == 4
    assert source.shape[0] > 0


def test_load_source_rejects_a_missing_image(tmp_path):
    with pytest.raises(RigError, match="could not read"):
        load_source(tmp_path / "missing.png")
