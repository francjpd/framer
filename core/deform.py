"""
Deform engine: a 2D rig / bones puppet-warp over a still image.

The math lives here and is deliberately free of any Port/CLI concerns: the
Elixir orchestrator only ever sends file paths, a frame range and JSON options
(the BEAM never sees pixels), so this module is driven by ``ops/deform.py``
(the CLI operation) and ``framer_worker.op_deform`` (the Port operation).

Model
-----
A rig is a versioned JSON document (``framer.rig`` / version ``1``) that holds:

* ``canvas``   - output size in pixels;
* ``bones``    - parent/child 2D segments with a rest ``head``/``tail`` and an
  influence ``radius``/``falloff``;
* ``keyframes``- per-bone local poses (``rot``/``tx``/``ty``) over time;
* ``duration`` - frame count / fps used when the source is a still image.

Deformation is linear blend skinning (LBS):

* every pixel gets a dense weight per bone, derived from the distance to the
  bone segment (``clamp(1 - d/radius, 0, 1) ** power``, normalized across
  bones, with an explicit nearest-bone fallback when every radius misses);
* a bone's local transform is a rotation about its rest head plus a
  translation; world transforms compose down the parent chain;
* a forward skinning matrix ``M(p) = sum_b w_b(p) A_b`` (2x2) and translation
  ``t(p) = sum_b w_b(p) t_b`` map rest pixels to output pixels;
* the backward map ``q -> p`` has no closed form, so it is solved with the
  standard fixed-point iteration, then sampled with ``cv2.remap``.

Weights depend only on the bind pose, so they are computed once and cached
in-process (and optionally to an ``.npz`` file), never per frame and never over
the Port.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# rig schema
# ---------------------------------------------------------------------------

SCHEMA = "framer.rig"
SCHEMA_VERSION = 1

# Fallback influence radius (pixels) when a bone does not declare one.  The
# report/design calls for a default around 10 px, adjustable per bone and
# globally through ``bind.radius_scale``.
DEFAULT_RADIUS = 10.0
DEFAULT_POWER = 2.0

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"}


class RigError(ValueError):
    """Raised when a rig document does not satisfy the schema."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise RigError(message)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validate_rig(rig: Any) -> dict[str, Any]:
    """
    Validate a rig document and return it unchanged.

    Raises :class:`RigError` with a human readable reason when the document is
    not a ``framer.rig`` v1 document.  Unknown versions fail loudly, exactly as
    the design requires (the editor and the engine share this validator).
    """
    _require(isinstance(rig, dict), "rig must be a JSON object")

    schema = rig.get("schema")
    _require(schema == SCHEMA, f"rig.schema must be {SCHEMA!r}, got {schema!r}")

    version = rig.get("version")
    _require(
        version == SCHEMA_VERSION,
        f"unsupported rig version {version!r}; expected {SCHEMA_VERSION}",
    )

    canvas = rig.get("canvas")
    _require(isinstance(canvas, dict), "rig.canvas must be an object")
    width = canvas.get("width")
    height = canvas.get("height")
    _require(
        isinstance(width, int) and width > 0,
        f"rig.canvas.width must be a positive integer, got {width!r}",
    )
    _require(
        isinstance(height, int) and height > 0,
        f"rig.canvas.height must be a positive integer, got {height!r}",
    )

    bones = rig.get("bones")
    _require(isinstance(bones, list) and len(bones) > 0, "rig.bones must be a non-empty list")

    seen: set[str] = set()
    for index, bone in enumerate(bones):
        _require(isinstance(bone, dict), f"rig.bones[{index}] must be an object")
        bone_id = bone.get("id")
        _require(
            isinstance(bone_id, str) and bone_id,
            f"rig.bones[{index}].id must be a non-empty string",
        )
        _require(bone_id not in seen, f"duplicate bone id {bone_id!r}")
        seen.add(bone_id)

        rest = bone.get("rest")
        _require(isinstance(rest, dict), f"bone {bone_id!r} is missing rest")
        for key in ("head", "tail"):
            point = rest.get(key)
            _require(
                isinstance(point, (list, tuple))
                and len(point) == 2
                and all(_is_number(v) for v in point),
                f"bone {bone_id!r}.rest.{key} must be [x, y]",
            )

        radius = bone.get("radius", DEFAULT_RADIUS)
        _require(
            _is_number(radius) and radius > 0,
            f"bone {bone_id!r}.radius must be a positive number",
        )

        falloff = bone.get("falloff", "smooth")
        _require(
            falloff in ("smooth", "linear", "hard"),
            f"bone {bone_id!r}.falloff must be smooth, linear or hard",
        )

    for index, bone in enumerate(bones):
        parent = bone.get("parent")
        _require(
            parent is None or (isinstance(parent, str) and parent in seen),
            f"rig.bones[{index}].parent {parent!r} is not a known bone",
        )

    _assert_acyclic(bones)

    keyframes = rig.get("keyframes", [])
    _require(isinstance(keyframes, list), "rig.keyframes must be a list")
    for index, keyframe in enumerate(keyframes):
        _require(isinstance(keyframe, dict), f"rig.keyframes[{index}] must be an object")
        frame = keyframe.get("frame")
        _require(
            isinstance(frame, int) and frame >= 0,
            f"rig.keyframes[{index}].frame must be a non-negative integer",
        )
        pose = keyframe.get("pose", {})
        _require(isinstance(pose, dict), f"rig.keyframes[{index}].pose must be an object")
        for bone_id, local in pose.items():
            _require(bone_id in seen, f"keyframe references unknown bone {bone_id!r}")
            _require(isinstance(local, dict), f"pose for {bone_id!r} must be an object")
            for key in ("rot", "tx", "ty"):
                value = local.get(key, 0.0)
                _require(_is_number(value), f"pose {bone_id!r}.{key} must be a number")

    bind = rig.get("bind", {})
    _require(isinstance(bind, dict), "rig.bind must be an object")
    power = bind.get("power", DEFAULT_POWER)
    _require(_is_number(power) and power >= 0, "rig.bind.power must be >= 0")
    radius_scale = bind.get("radius_scale", 1.0)
    _require(_is_number(radius_scale) and radius_scale > 0, "rig.bind.radius_scale must be > 0")

    duration = rig.get("duration", {})
    _require(isinstance(duration, dict), "rig.duration must be an object")
    if "frames" in duration:
        _require(
            isinstance(duration["frames"], int) and duration["frames"] > 0,
            "rig.duration.frames must be a positive integer",
        )
    if "fps" in duration:
        _require(
            _is_number(duration["fps"]) and duration["fps"] > 0,
            "rig.duration.fps must be > 0",
        )

    return rig


def _assert_acyclic(bones: Sequence[dict[str, Any]]) -> None:
    parents = {bone["id"]: bone.get("parent") for bone in bones}
    for bone_id, parent in parents.items():
        seen = {bone_id}
        current = parent
        while current is not None:
            if current in seen:
                raise RigError(f"cycle detected in bone hierarchy at {bone_id!r}")
            seen.add(current)
            current = parents.get(current)


def load_rig(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Load and validate a rig JSON document from disk."""
    rig_path = Path(path)
    if not rig_path.exists():
        raise RigError(f"rig file not found: {rig_path}")

    try:
        with open(rig_path, "r", encoding="utf-8") as handle:
            rig = json.load(handle)
    except json.JSONDecodeError as exc:
        raise RigError(f"rig file is not valid JSON: {exc}") from exc

    return validate_rig(rig)


def rig_fingerprint(rig: dict[str, Any]) -> str:
    """Stable fingerprint of the parts of a rig that determine the weights."""
    relevant = {
        "canvas": rig.get("canvas"),
        "bones": [
            {
                "id": bone.get("id"),
                "parent": bone.get("parent"),
                "rest": bone.get("rest"),
                "radius": bone.get("radius", DEFAULT_RADIUS),
                "falloff": bone.get("falloff", "smooth"),
            }
            for bone in rig.get("bones", [])
        ],
        "bind": rig.get("bind", {}),
    }
    blob = json.dumps(relevant, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha1(blob).hexdigest()


# ---------------------------------------------------------------------------
# weights
# ---------------------------------------------------------------------------

def _bone_segments(rig: dict[str, Any]) -> list[tuple[float, float, float, float]]:
    segments = []
    for bone in rig["bones"]:
        head = bone["rest"]["head"]
        tail = bone["rest"]["tail"]
        segments.append((float(head[0]), float(head[1]), float(tail[0]), float(tail[1])))
    return segments


def _distance_to_segment(
    grid_x: np.ndarray,
    grid_y: np.ndarray,
    ax: float,
    ay: float,
    bx: float,
    by: float,
) -> np.ndarray:
    vx = bx - ax
    vy = by - ay
    wx = grid_x - ax
    wy = grid_y - ay
    seg_len2 = vx * vx + vy * vy

    if seg_len2 <= 1e-12:
        return np.sqrt(wx * wx + wy * wy)

    t = np.clip((wx * vx + wy * vy) / seg_len2, 0.0, 1.0)
    dx = wx - t * vx
    dy = wy - t * vy
    return np.sqrt(dx * dx + dy * dy)


def _falloff_power(falloff: str, default_power: float) -> float:
    if falloff == "linear":
        return 1.0
    if falloff == "hard":
        return 0.0
    return default_power


def compute_dense_weights(
    rig: dict[str, Any],
    width: int | None = None,
    height: int | None = None,
) -> np.ndarray:
    """
    Compute dense per-pixel bone weights for the bind pose.

    Returns a ``(num_bones, height, width)`` ``float32`` array whose columns sum
    to 1 along the bone axis.  Pixels outside every influence radius fall back
    to their nearest bone so no pixel is left unweighted.
    """
    width = int(width if width is not None else rig["canvas"]["width"])
    height = int(height if height is not None else rig["canvas"]["height"])

    grid_x, grid_y = np.meshgrid(
        np.arange(width, dtype=np.float32),
        np.arange(height, dtype=np.float32),
    )

    bind = rig.get("bind", {})
    default_power = float(bind.get("power", DEFAULT_POWER))
    radius_scale = float(bind.get("radius_scale", 1.0))

    weights: list[np.ndarray] = []
    distances: list[np.ndarray] = []

    for bone, segment in zip(rig["bones"], _bone_segments(rig)):
        distance = _distance_to_segment(grid_x, grid_y, *segment)
        radius = float(bone.get("radius", DEFAULT_RADIUS)) * radius_scale
        exponent = _falloff_power(bone.get("falloff", "smooth"), default_power)

        influence = np.clip(1.0 - distance / max(radius, 1e-6), 0.0, 1.0)
        if exponent == 0.0:
            influence = (influence > 0).astype(np.float32)
        else:
            influence = np.power(influence, exponent, dtype=np.float32)

        weights.append(influence.astype(np.float32))
        distances.append(distance.astype(np.float32))

    stacked = np.stack(weights, axis=0)
    distance_stack = np.stack(distances, axis=0)

    total = stacked.sum(axis=0)
    normalized = np.where(total > 0.0, stacked / np.maximum(total, 1e-8), stacked)

    missing = total <= 0.0
    if np.any(missing):
        nearest = np.argmin(distance_stack, axis=0)
        one_hot = np.zeros_like(stacked)
        np.put_along_axis(one_hot, nearest[np.newaxis, :, :], 1.0, axis=0)
        normalized = np.where(missing[np.newaxis, :, :], one_hot, normalized)

    return normalized.astype(np.float32)


def load_or_build_weights(
    rig: dict[str, Any],
    width: int | None = None,
    height: int | None = None,
    cache_path: str | os.PathLike[str] | None = None,
) -> np.ndarray:
    """
    Return the dense weights for ``rig``, using an ``.npz`` cache when possible.

    The in-process module cache is keyed on the rig fingerprint so a long lived
    Port worker binds a rig once.  When ``cache_path`` is given and exists it is
    loaded; otherwise the weights are computed and written back atomically
    (best effort - a read-only cache directory must not fail the render).
    """
    fingerprint = rig_fingerprint(rig)
    cache_key = (fingerprint, width, height)
    cached = _WEIGHT_CACHE.get(cache_key)
    if cached is not None:
        return cached

    cache_file = Path(cache_path) if cache_path else None
    if cache_file and cache_file.exists():
        try:
            with np.load(cache_file) as data:
                weights = data["weights"].astype(np.float32)
            _WEIGHT_CACHE[cache_key] = weights
            return weights
        except (OSError, ValueError, KeyError):
            # Corrupt or foreign cache: fall through and recompute.
            pass

    weights = compute_dense_weights(rig, width=width, height=height)

    if cache_file:
        _write_weights_atomic(cache_file, weights)

    _WEIGHT_CACHE[cache_key] = weights
    return weights


_WEIGHT_CACHE: dict[tuple[str, int | None, int | None], np.ndarray] = {}


def _write_weights_atomic(path: Path, weights: np.ndarray) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_path = tempfile.mkstemp(suffix=".npz", dir=str(path.parent))
        os.close(fd)
        np.savez_compressed(temp_path, weights=weights)
        os.replace(temp_path, path)
    except OSError:
        # Cache is an optimisation only; never fail a render because of it.
        pass


# ---------------------------------------------------------------------------
# control mesh (bind pose)
# ---------------------------------------------------------------------------

def build_grid_mesh(
    rig: dict[str, Any],
    cell_size: float | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Build the bind-pose control mesh as a regular grid over the canvas.

    Returns ``(vertices, triangles)``: ``vertices`` is ``(N, 2)`` float32 in
    image space and ``triangles`` is ``(M, 3)`` int32 indexing into it.  This is
    the wireframe the editor draws; the renderer itself uses the dense weights,
    so a coarse mesh never shows up as seams in the deformed output.
    """
    width = int(rig["canvas"]["width"])
    height = int(rig["canvas"]["height"])

    if cell_size is None:
        cell_size = max(8.0, min(width, height) / 8.0)
    cell_size = float(cell_size)

    cols = max(2, math.ceil(width / cell_size) + 1)
    rows = max(2, math.ceil(height / cell_size) + 1)

    xs = np.linspace(0.0, float(width - 1), cols, dtype=np.float32)
    ys = np.linspace(0.0, float(height - 1), rows, dtype=np.float32)
    grid_x, grid_y = np.meshgrid(xs, ys)
    vertices = np.stack([grid_x.ravel(), grid_y.ravel()], axis=1).astype(np.float32)

    triangles = []
    for row in range(rows - 1):
        for col in range(cols - 1):
            top_left = row * cols + col
            top_right = top_left + 1
            bottom_left = (row + 1) * cols + col
            bottom_right = bottom_left + 1
            triangles.append([top_left, top_right, bottom_right])
            triangles.append([top_left, bottom_right, bottom_left])

    return vertices, np.asarray(triangles, dtype=np.int32)


def compute_vertex_weights(
    rig: dict[str, Any],
    vertices: np.ndarray,
) -> np.ndarray:
    """
    Weight mesh vertices with the same distance/radius/falloff rule as pixels.

    Returns ``(len(vertices), num_bones)`` ``float32`` rows summing to 1.  This
    is the compact form an editor can preview; the renderer interpolates the
    dense form instead.
    """
    vertices = np.asarray(vertices, dtype=np.float32)
    grid_x = vertices[:, 0]
    grid_y = vertices[:, 1]

    bind = rig.get("bind", {})
    default_power = float(bind.get("power", DEFAULT_POWER))
    radius_scale = float(bind.get("radius_scale", 1.0))

    columns = []
    for bone, segment in zip(rig["bones"], _bone_segments(rig)):
        distance = _distance_to_segment(grid_x, grid_y, *segment)
        radius = float(bone.get("radius", DEFAULT_RADIUS)) * radius_scale
        exponent = _falloff_power(bone.get("falloff", "smooth"), default_power)

        influence = np.clip(1.0 - distance / max(radius, 1e-6), 0.0, 1.0)
        if exponent == 0.0:
            influence = (influence > 0).astype(np.float32)
        else:
            influence = np.power(influence, exponent, dtype=np.float32)
        columns.append(influence.astype(np.float32))

    stacked = np.stack(columns, axis=1)
    total = stacked.sum(axis=1, keepdims=True)
    normalized = np.where(total > 0.0, stacked / np.maximum(total, 1e-8), stacked)

    missing = (total[:, 0] <= 0.0)
    if np.any(missing):
        # fall back to the nearest bone for the unweighted vertices
        distances = np.stack(
            [
                _distance_to_segment(grid_x, grid_y, *segment)
                for segment in _bone_segments(rig)
            ],
            axis=1,
        )
        nearest = np.argmin(distances, axis=1)
        normalized[missing] = 0.0
        normalized[np.nonzero(missing)[0], nearest[missing]] = 1.0

    return normalized.astype(np.float32)


# ---------------------------------------------------------------------------
# bone evaluation / keyframes
# ---------------------------------------------------------------------------

def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def interpolate_keyframes(rig: dict[str, Any], frame: int) -> dict[str, dict[str, float]]:
    """
    Interpolate per-bone local poses at ``frame``.

    Linear interpolation between the surrounding keyframes; frames before the
    first or after the last keyframe clamp.  Missing bones default to identity.
    """
    keyframes = sorted(rig.get("keyframes") or [], key=lambda k: k["frame"])
    zero = {"rot": 0.0, "tx": 0.0, "ty": 0.0}

    if not keyframes:
        return {bone["id"]: dict(zero) for bone in rig["bones"]}

    if frame <= keyframes[0]["frame"]:
        return {
            bone["id"]: {**zero, **(keyframes[0].get("pose", {}).get(bone["id"]) or {})}
            for bone in rig["bones"]
        }

    if frame >= keyframes[-1]["frame"]:
        return {
            bone["id"]: {**zero, **(keyframes[-1].get("pose", {}).get(bone["id"]) or {})}
            for bone in rig["bones"]
        }

    left = keyframes[0]
    right = keyframes[-1]
    for index in range(len(keyframes) - 1):
        if keyframes[index]["frame"] <= frame <= keyframes[index + 1]["frame"]:
            left = keyframes[index]
            right = keyframes[index + 1]
            break

    span = right["frame"] - left["frame"]
    t = 0.0 if span <= 0 else (frame - left["frame"]) / span

    poses: dict[str, dict[str, float]] = {}
    for bone in rig["bones"]:
        bone_id = bone["id"]
        left_pose = {**zero, **(left.get("pose", {}).get(bone_id) or {})}
        right_pose = {**zero, **(right.get("pose", {}).get(bone_id) or {})}
        poses[bone_id] = {
            key: _lerp(float(left_pose[key]), float(right_pose[key]), t)
            for key in ("rot", "tx", "ty")
        }
    return poses


def bone_local_matrix(head: Sequence[float], pose: dict[str, float]) -> np.ndarray:
    """Rotation about the rest head followed by a translation, as a 3x3 matrix."""
    rot = float(pose.get("rot", 0.0))
    tx = float(pose.get("tx", 0.0))
    ty = float(pose.get("ty", 0.0))

    cosine, sine = math.cos(rot), math.sin(rot)
    rotation = np.array([[cosine, -sine], [sine, cosine]], dtype=np.float64)
    head_vec = np.array([float(head[0]), float(head[1])], dtype=np.float64)

    matrix = np.eye(3, dtype=np.float64)
    matrix[:2, :2] = rotation
    matrix[:2, 2] = head_vec - rotation @ head_vec + np.array([tx, ty], dtype=np.float64)
    return matrix


def evaluate_bones(
    rig: dict[str, Any],
    frame: int,
    poses: dict[str, dict[str, float]] | None = None,
) -> list[np.ndarray]:
    """
    World transform for every bone at ``frame`` (same order as ``rig.bones``).

    ``poses`` overrides the keyframe lookup; passing identity poses computes the
    bind-pose world transforms.
    """
    if poses is None:
        poses = interpolate_keyframes(rig, frame)

    bones_by_id = {bone["id"]: bone for bone in rig["bones"]}
    world: dict[str, np.ndarray] = {}

    def resolve(bone: dict[str, Any], stack: tuple[str, ...]) -> np.ndarray:
        bone_id = bone["id"]
        if bone_id in world:
            return world[bone_id]
        if bone_id in stack:
            raise RigError(f"cycle detected while evaluating bone {bone_id!r}")

        local = bone_local_matrix(
            bone["rest"]["head"], poses.get(bone_id, {"rot": 0.0, "tx": 0.0, "ty": 0.0})
        )
        parent_id = bone.get("parent")
        if parent_id and parent_id in bones_by_id:
            world_matrix = resolve(bones_by_id[parent_id], stack + (bone_id,)) @ local
        else:
            world_matrix = local

        world[bone_id] = world_matrix
        return world_matrix

    return [resolve(bone, ()) for bone in rig["bones"]]


def _bind_poses(rig: dict[str, Any]) -> dict[str, dict[str, float]]:
    return {bone["id"]: {"rot": 0.0, "tx": 0.0, "ty": 0.0} for bone in rig["bones"]}


# ---------------------------------------------------------------------------
# skinning / backward map
# ---------------------------------------------------------------------------

def skinning_fields(
    world: Sequence[np.ndarray],
    bind: Sequence[np.ndarray],
    weights: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Weighted skinning matrix field ``A`` (H, W, 2, 2) and translation ``t`` (H, W, 2).

    Each bone contributes ``A_b = W_b @ B_b^{-1}`` and the blend is the
    per-pixel weight combination.
    """
    num_bones = weights.shape[0]
    matrices = np.empty((num_bones, 2, 2), dtype=np.float32)
    translations = np.empty((num_bones, 2), dtype=np.float32)

    for index in range(num_bones):
        skin = world[index] @ np.linalg.inv(bind[index])
        matrices[index] = skin[:2, :2].astype(np.float32)
        translations[index] = skin[:2, 2].astype(np.float32)

    matrix_field = np.tensordot(weights, matrices, axes=([0], [0])).astype(np.float32)
    translation_field = np.tensordot(weights, translations, axes=([0], [0])).astype(np.float32)
    return matrix_field, translation_field


def compute_backward_map(
    matrix_field: np.ndarray,
    translation_field: np.ndarray,
    iterations: int = 5,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Solve ``F(p) = q`` for every output pixel ``q`` with a fixed-point iteration.

    Returns ``(map_x, map_y)`` float32 arrays suitable for ``cv2.remap``: for
    output pixel ``(x, y)`` the source sample is ``(map_x[y, x], map_y[y, x])``.
    """
    height, width = matrix_field.shape[:2]

    grid_x, grid_y = np.meshgrid(
        np.arange(width, dtype=np.float32),
        np.arange(height, dtype=np.float32),
    )
    query = np.stack([grid_x, grid_y], axis=-1)

    estimate = query.copy()
    for _ in range(max(1, int(iterations))):
        sample_x = np.clip(np.rint(estimate[..., 0]), 0, width - 1).astype(np.int32)
        sample_y = np.clip(np.rint(estimate[..., 1]), 0, height - 1).astype(np.int32)

        matrix = matrix_field[sample_y, sample_x]
        translation = translation_field[sample_y, sample_x]

        a = matrix[..., 0, 0]
        b = matrix[..., 0, 1]
        c = matrix[..., 1, 0]
        d = matrix[..., 1, 1]
        determinant = a * d - b * c
        safe_determinant = np.where(np.abs(determinant) < 1e-8, 1e-8, determinant)

        rhs_x = query[..., 0] - translation[..., 0]
        rhs_y = query[..., 1] - translation[..., 1]

        estimate = np.stack(
            [
                (d * rhs_x - b * rhs_y) / safe_determinant,
                (-c * rhs_x + a * rhs_y) / safe_determinant,
            ],
            axis=-1,
        ).astype(np.float32)

    return estimate[..., 0], estimate[..., 1]


def apply_lbs(
    source: np.ndarray,
    weights: np.ndarray,
    world: Sequence[np.ndarray],
    bind: Sequence[np.ndarray],
    iterations: int = 5,
) -> np.ndarray:
    """Deform a single BGRA (or BGR) frame with linear blend skinning."""
    matrix_field, translation_field = skinning_fields(world, bind, weights)
    map_x, map_y = compute_backward_map(matrix_field, translation_field, iterations)

    return cv2.remap(
        source,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0, 0) if source.ndim == 3 and source.shape[2] == 4 else (0, 0, 0),
    )


# ---------------------------------------------------------------------------
# source loading / high level renderer
# ---------------------------------------------------------------------------

# JPEG EXIF orientation values (the transform to apply to the stored pixels to
# display them upright). Browsers apply this automatically when they decode a
# still; OpenCV does not, so the editor's preview and the engine would disagree
# on phone photographs unless the engine applies the same transform.
_EXIF_ORIENTATION_UPRIGHT = 1


def _read_jpeg_exif_orientation(path: str | os.PathLike[str]) -> int:
    """Return the EXIF orientation (1..8) of a JPEG, or 1 when absent/unknown."""
    try:
        with open(path, "rb") as handle:
            # The EXIF APP1 segment always precedes the entropy-coded data, so
            # the first 256 KiB is far more than enough to find it.
            data = handle.read(1 << 18)
    except OSError:
        return _EXIF_ORIENTATION_UPRIGHT

    if not data.startswith(b"\xFF\xD8"):
        return _EXIF_ORIENTATION_UPRIGHT

    position = 2
    size = len(data)
    while position + 4 <= size:
        if data[position] != 0xFF:
            break
        marker = data[position + 1]

        # Fill byte before the real marker.
        if marker == 0xFF:
            position += 1
            continue

        # Standalone markers (no length field): TEM, RSTn, SOI, EOI.
        if marker in (0x01, 0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            position += 2
            continue

        # A Start-Of-Frame means the metadata is done; orientation would have
        # appeared before it.
        if marker in range(0xC0, 0xD0) and marker not in (0xC4, 0xC8, 0xCC):
            break

        if position + 2 > size:
            break
        segment_length = int.from_bytes(data[position + 2 : position + 4], "big")
        if segment_length < 2 or position + 2 + segment_length > size:
            break
        segment = data[position + 4 : position + 2 + segment_length]

        if marker == 0xE1 and segment.startswith(b"Exif\x00\x00"):
            orientation = _tiff_exif_orientation(segment[6:])
            if orientation is not None:
                return orientation

        position += 2 + segment_length

    return _EXIF_ORIENTATION_UPRIGHT


def _tiff_exif_orientation(tiff: bytes) -> int | None:
    """Read the IFD0 orientation tag from a little/big-endian TIFF blob."""
    if len(tiff) < 8:
        return None
    if tiff[0:2] == b"II":
        endian = "little"
    elif tiff[0:2] == b"MM":
        endian = "big"
    else:
        return None

    offset = int.from_bytes(tiff[4:8], endian)
    if offset + 2 > len(tiff):
        return None

    count = int.from_bytes(tiff[offset : offset + 2], endian)
    entries = tiff[offset + 2 :]
    for _index in range(count):
        entry = entries[:12]
        if len(entry) < 12:
            return None
        entries = entries[12:]
        tag = int.from_bytes(entry[0:2], endian)
        if tag == 0x0112 and int.from_bytes(entry[2:4], endian) == 3:
            return int.from_bytes(entry[8:10], endian)
    return None


def _apply_exif_orientation(image: np.ndarray, orientation: int) -> np.ndarray:
    """Apply the EXIF orientation transform to an OpenCV image (in place-safe)."""
    if orientation == 2:
        return cv2.flip(image, 1)
    if orientation == 3:
        return cv2.rotate(image, cv2.ROTATE_180)
    if orientation == 4:
        return cv2.flip(image, 0)
    if orientation == 5:
        return cv2.transpose(image)
    if orientation == 6:
        return cv2.rotate(image, cv2.ROTATE_90_CLOCKWISE)
    if orientation == 7:
        return cv2.rotate(cv2.flip(image, 1), cv2.ROTATE_90_CLOCKWISE)
    if orientation == 8:
        return cv2.rotate(image, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return image


def load_source_image(path: str | os.PathLike[str]) -> np.ndarray:
    """Read a still image as BGRA, adding an opaque alpha plane when absent."""
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None:
        raise RigError(f"could not read source image: {path}")

    # Match the browser's EXIF handling so the engine renders the orientation
    # the editor previews. Non-JPEG inputs carry no orientation and pass
    # through unchanged.
    orientation = _read_jpeg_exif_orientation(str(path))
    image = _apply_exif_orientation(image, orientation)

    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGRA)
    elif image.shape[2] == 3:
        alpha = np.full(image.shape[:2] + (1,), 255, dtype=np.uint8)
        image = np.concatenate([image, alpha], axis=2)
    elif image.shape[2] != 4:
        raise RigError(f"unsupported source image shape: {image.shape}")

    return np.ascontiguousarray(image)


def read_first_video_frame(path: str | os.PathLike[str]) -> np.ndarray:
    """Fallback for video sources: read the first decoded frame as BGRA."""
    import cv2 as _cv2

    capture = _cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise RigError(f"could not open source video: {path}")
    try:
        ok, frame = capture.read()
    finally:
        capture.release()

    if not ok or frame is None:
        raise RigError(f"could not read a frame from source video: {path}")

    return cv2.cvtColor(frame, cv2.COLOR_BGR2BGRA) if frame.ndim == 3 else frame


def is_image_path(path: str | os.PathLike[str]) -> bool:
    return Path(path).suffix.lower() in IMAGE_EXTENSIONS


def load_source(
    path: str | os.PathLike[str],
    still: bool | None = None,
) -> np.ndarray:
    """
    Load the deformation source, honouring the still-image convention.

    When ``still`` is ``None`` the extension decides; a still is read once with
    ``cv2.imread`` and then looped over the requested frame range by the caller.
    """
    if still is None:
        still = is_image_path(path)

    if still:
        return load_source_image(path)
    return read_first_video_frame(path)


class DeformRenderer:
    """
    Bind a rig to a still source and render frames on demand.

    The renderer owns the source image and the (cached) dense weights; calling
    :meth:`render` only re-evaluates bones and runs the skinning, which is what
    makes chunked export cheap.
    """

    def __init__(
        self,
        rig: dict[str, Any],
        source: np.ndarray,
        iterations: int = 5,
        weights: np.ndarray | None = None,
        weights_cache: str | os.PathLike[str] | None = None,
        still: bool | None = None,
    ):
        self.rig = validate_rig(rig)

        canvas_width = int(self.rig["canvas"]["width"])
        canvas_height = int(self.rig["canvas"]["height"])
        if source.shape[1] != canvas_width or source.shape[0] != canvas_height:
            source = cv2.resize(
                source, (canvas_width, canvas_height), interpolation=cv2.INTER_LINEAR
            )
        self.source = np.ascontiguousarray(source)
        self.width = canvas_width
        self.height = canvas_height
        self.iterations = max(1, int(iterations))

        if weights is None:
            weights = load_or_build_weights(
                self.rig, width=self.width, height=self.height, cache_path=weights_cache
            )
        weights = np.asarray(weights, dtype=np.float32)
        if weights.shape[0] != len(self.rig["bones"]):
            raise RigError(
                f"weights have {weights.shape[0]} bones but rig has {len(self.rig['bones'])}"
            )
        if weights.shape[1:] != (self.height, self.width):
            raise RigError(
                f"weights shape {weights.shape[1:]} does not match canvas "
                f"{(self.height, self.width)}"
            )
        self.weights = weights

        poses = _bind_poses(self.rig)
        self.bind = evaluate_bones(self.rig, 0, poses=poses)

    def render(self, frame: int) -> np.ndarray:
        """Render one frame index to a BGRA image."""
        world = evaluate_bones(self.rig, int(frame))
        return apply_lbs(self.source, self.weights, world, self.bind, self.iterations)

    def render_to_png(
        self,
        frame: int,
        output_path: str | os.PathLike[str],
    ) -> str:
        """Render one frame and write it to ``output_path`` as a PNG."""
        image = self.render(frame)
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(output), image):
            raise RigError(f"could not write rendered frame to {output}")
        return str(output)
