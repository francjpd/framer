"""
The feathered background patch: the region the character can uncover.

A split rig composites the deformed character over an opaque background
plate.  The plate reconstructs the character's *rest footprint* - the area the
character occupied in the still - from the surrounding background, so a frame
never shows a hole.  But the character also *travels*: the union of its warped
footprints over the timeline reaches past the rest footprint, and there the
plate still shows the original background.  The character therefore slides from
the plate's reconstructed rest area onto untouched background - two different
materials under one moving character.

This module builds the third materialised layer that closes that gap:

* ``character_region`` - the region, computed from the skeleton with the
  engine's own LBS: the union of the character's warped footprints over the
  whole timeline, minus its own rest footprint.
* ``reconstruct`` - the region reconstructed from the *plate*, never from the
  still: inpainting from the still leaks the character's own pixels into the
  synthesis (measured, textured background: 46.9 vs 34.5 mean error).
* ``feather_ramp`` - the alpha ramp over the region: fully opaque in the
  middle, 0 at the region's edge, so the patch merges into the untouched
  background around it.  This is the shared primitive the healing brush
  reuses, which is why it lives in its own module.
* ``build_patch`` / ``resolve_patch_layer`` - the BGRA patch layer, written
  beside the still as ``patch.png``.

The feather lives on this layer and never on the plate.  A feathered *plate*
leaves a transparent ring in every frame; the plate underneath an opaque patch
keeps the frame fully opaque.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from core.deform import apply_lbs, bind_poses, evaluate_bones, load_or_build_weights
from core.errors import RigError
from core.layers import (
    DEFAULT_FADE,
    PATCH_FILENAME,
    has_background_layer,
    has_patch_layer,
    layer_settings,
    load_layer,
    patch_fade,
    patch_path,
    write_layer,
)

# The sidecar that records what the patch was built from, so a rig that
# changed rebuilds it instead of reusing a stale file.
PATCH_META_FILENAME = "patch.json"

# The alpha above which a pixel counts as character.  Named, not magic: a
# soft-edged character mask makes this a real choice.
ALPHA_THRESHOLD = 127

# The frame count a rig without a duration falls back to, the same default the
# editor shows for it, so the two never disagree about the same document.
DEFAULT_FRAMES = 48

# The inpaint radius for the reconstruction.  The plate uses 3; the region is
# larger and softer, so it gets a slightly wider fill.
INPAINT_RADIUS = 5


def character_region(
    rig: dict[str, Any],
    alpha: np.ndarray,
    *,
    weights: np.ndarray | None = None,
    iterations: int = 5,
) -> np.ndarray:
    """
    The region the character can uncover: the union of its warped footprints
    over the timeline, minus its own rest footprint.

    The region is exactly the swept area: the rest footprint keeps the plate's
    own reconstruction of it, and the feather ramps from the swept area's edge.

    Args:
        rig: the rig document, whose bones and keyframes define the motion.
        alpha: ``(H, W)`` uint8 character mask in canvas space.
        weights: dense bone weights, reused when the caller already has them.
        iterations: fixed-point iterations of the backward map.

    Returns:
        A ``(H, W)`` uint8 mask, 255 inside the region.
    """
    size = int(rig["canvas"]["width"])
    height = int(rig["canvas"]["height"])
    alpha = np.asarray(alpha, dtype=np.uint8)
    if alpha.shape != (height, size):
        raise RigError(f"character mask shape {alpha.shape} does not match the canvas")

    if weights is None:
        weights = load_or_build_weights(rig, width=size, height=height)
    union = np.zeros((height, size), np.uint8)
    bind = evaluate_bones(rig, 0, poses=bind_poses(rig))
    mask = np.concatenate(
        [np.zeros((height, size, 3), np.uint8), alpha[:, :, None]], axis=2
    )

    for frame in timeline_frames(rig):
        world = evaluate_bones(rig, frame)
        warped = apply_lbs(mask, weights, world, bind, iterations)
        union = np.maximum(union, (warped[:, :, 3] > ALPHA_THRESHOLD).astype(np.uint8) * 255)

    rest = (alpha > ALPHA_THRESHOLD).astype(np.uint8) * 255
    region = ((union > 0) & (rest == 0)).astype(np.uint8) * 255
    return region


def _layer_digest(layer: np.ndarray | None) -> str | None:
    """
    The content digest of a layer, or None when there is no layer.

    The digest is of the decoded pixels, so it does not depend on how the
    layer file is encoded and a copy of the same layer has the same identity.
    """
    if layer is None:
        return None
    return hashlib.sha1(np.ascontiguousarray(layer).tobytes()).hexdigest()


def patch_fingerprint(
    rig: dict[str, Any],
    character: np.ndarray | None = None,
    plate: np.ndarray | None = None,
) -> str:
    """
    A stable fingerprint of everything the patch is built from.

    The region depends on the skeleton and on the motion over the timeline,
    the reconstruction depends on the character mask and on the background
    plate, and the feather depends on the fade - so a change to any of them
    means the materialised patch is stale.

    The two layers are part of it by their *content*, so replacing either
    layer (the editor's "Change" action) rebuilds the patch instead of reusing
    a patch built from the old material.  The digest is of the decoded pixels,
    so a copy of the same layer - the export snapshots the layers beside the
    still - keeps the patch reusable.
    """
    relevant = {
        "canvas": rig.get("canvas"),
        "duration": rig.get("duration"),
        "bones": [
            {
                "id": bone.get("id"),
                "parent": bone.get("parent"),
                "rest": bone.get("rest"),
                "radius": bone.get("radius"),
                "falloff": bone.get("falloff"),
            }
            for bone in rig.get("bones", [])
        ],
        "bind": rig.get("bind", {}),
        "keyframes": rig.get("keyframes"),
        "mask": layer_settings(rig),
        "fade": patch_fade(rig),
        "plate": _layer_digest(plate),
        "character": _layer_digest(character),
    }
    blob = json.dumps(relevant, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha1(blob).hexdigest()


def read_patch_meta(path: str | Path) -> dict[str, Any] | None:
    """What the materialised patch records about itself, if anything."""
    meta = Path(path).parent / PATCH_META_FILENAME
    if not meta.exists():
        return None
    try:
        payload = json.loads(meta.read_text())
    except (OSError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def write_patch_meta(path: str | Path, payload: dict[str, Any]) -> Path:
    """Record what the materialised patch was built from."""
    meta = Path(path).parent / PATCH_META_FILENAME
    meta.parent.mkdir(parents=True, exist_ok=True)
    # The sidecar is written atomically: a reader never sees a half-written
    # file, which would read as "no sidecar" and force another rebuild.
    temp = meta.with_name(f".{meta.name}.tmp.{uuid.uuid4().hex}")
    temp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temp.replace(meta)
    return meta


def timeline_frames(rig: dict[str, Any]) -> list[int]:
    """
    The frames the region's union is taken over.

    Every frame of the timeline is sampled: the region is the character's
    swept area, and a stride would leave a hole wherever the character travels
    further between two sampled frames than its own footprint is wide.  A rig
    without a duration falls back to the same frame count the editor shows for
    it, so the two never disagree about the same document.
    """
    duration = rig.get("duration") or {}
    frames = int(duration.get("frames") or DEFAULT_FRAMES)
    if frames <= 0:
        return []
    return list(range(frames))


def reconstruct(plate: np.ndarray, region: np.ndarray, radius: int = INPAINT_RADIUS) -> np.ndarray:
    """
    Reconstruct the region from the surrounding background.

    ``plate`` is the background-only image (the shipped plate), NOT the still:
    inpainting from the still leaks the character's own pixels into the
    reconstruction (measured, textured background: 46.9 vs 34.5 mean error).
    """
    bgr = plate[:, :, :3] if plate.ndim == 3 and plate.shape[2] == 4 else plate
    if region.max() == 0:
        return bgr.copy()
    return cv2.inpaint(bgr, region, radius, cv2.INPAINT_TELEA)


def feather_ramp(region: np.ndarray, fade: int) -> np.ndarray:
    """
    The alpha ramp: fully opaque in the middle of the region, 0 at its edge.

    ``fade`` is the width of the ramp in pixels (0 = no feather, the region is
    opaque up to its boundary).  This is the shared primitive the healing
    brush will reuse, so it belongs in its own module.
    """
    if region.max() == 0:
        return np.zeros(region.shape, np.uint8)
    if fade <= 0:
        return np.where(region > 0, 255, 0).astype(np.uint8)
    distance = cv2.distanceTransform((region > 0).astype(np.uint8), cv2.DIST_L2, 3)
    inner = np.clip((distance - 1.0) / float(fade), 0.0, 1.0)
    return (inner * 255).astype(np.uint8)


def build_patch(
    rig: dict[str, Any],
    alpha: np.ndarray,
    plate: np.ndarray,
    *,
    fade: int = DEFAULT_FADE,
    weights: np.ndarray | None = None,
    iterations: int = 5,
) -> np.ndarray:
    """
    The patch layer: BGRA, the reconstructed region with the feathered alpha.

    The colour is the plate with the region reconstructed from it, so the
    character's rest footprint is already reconstructed (the plate did that
    first) and the swept-only part is inpainted from background-only pixels.
    The alpha ramps over the region, so the patch is opaque where the
    character travels and merges into the untouched background at the region's
    edge.
    """
    region = character_region(rig, alpha, weights=weights, iterations=iterations)
    colour = reconstruct(plate, region)
    ramp = feather_ramp(region, fade)
    return np.concatenate([colour, ramp[:, :, None]], axis=2)


def resolve_patch_layer(
    rig: dict[str, Any],
    source_path: str | Path,
    character: np.ndarray,
    plate: np.ndarray,
    *,
    weights: np.ndarray | None = None,
    iterations: int = 5,
    build: bool = True,
) -> tuple[np.ndarray | None, Path | None]:
    """
    Return the patch layer for a rig, materialising it when it is missing.

    The patch is a project-level artefact: it is computed once from the
    skeleton and reused by every frame, every preview and every export.  It is
    only computed for a rig that asks for one (the document records a fade) and
    that has a skeleton - the region the character can uncover is only known
    once the bones and the timeline exist.  It also needs the background plate:
    the reconstruction is made from the plate, so a rig without one has no
    patch at all (and the renderer skips the patch in that case anyway).

    The character layer and the plate are the ones the caller resolved, so the
    layer files are decoded once per operation.

    With ``build=False`` the materialised patch is used when it still matches
    the rig and nothing is ever built: a caller that must not pay for the
    whole-timeline sweep gets the patch the project already has, or none.  The
    sidecar's fingerprint decides whether it still matches, so a patch built
    for another rig is never composited.

    Returns:
        ``(patch, written_path)``; ``written_path`` is ``None`` when an
        existing file was reused.  A rig without a patch layer returns
        ``(None, None)``.
    """
    if not has_patch_layer(rig):
        return None, None

    fade = patch_fade(rig)
    if fade is None:
        return None, None

    if not rig.get("bones"):
        # No skeleton, no motion, no region: the patch waits for the rig to
        # have bones rather than guessing one.
        return None, None

    if not timeline_frames(rig):
        # No timeline to sweep over, so there is no region to reconstruct.
        return None, None

    if not has_background_layer(rig):
        # Without the plate there is no background to heal against, so there is
        # no patch to build.
        return None, None

    path = patch_path(source_path)
    fingerprint = patch_fingerprint(rig, character, plate)

    if path.exists():
        meta = read_patch_meta(path)
        if meta and meta.get("fingerprint") == fingerprint:
            return load_layer(path), None
        # The rig changed since the patch was built: it is stale.

    if not build:
        # The caller asked for the materialised patch only: it is missing or
        # stale, and this call never builds one.  The sidecar's fingerprint is
        # what decides, so a patch built for another rig is never composited.
        return None, None

    size = int(rig["canvas"]["width"])
    height = int(rig["canvas"]["height"])

    alpha = _resize(character[:, :, 3], size, height)
    plate = _resize(plate, size, height)

    patch = build_patch(
        rig, alpha, plate, fade=fade, weights=weights, iterations=iterations
    )
    write_layer(path, patch)
    write_patch_meta(
        path,
        {
            "fingerprint": fingerprint,
            "fade": fade,
            "region_px": int((patch[:, :, 3] > 0).sum()),
        },
    )
    return patch, path


def _resize(layer: np.ndarray, width: int, height: int) -> np.ndarray:
    """Resize a layer to the canvas size, the way the renderer does."""
    if layer.shape[1] == width and layer.shape[0] == height:
        return layer
    return cv2.resize(layer, (width, height), interpolation=cv2.INTER_LINEAR)


__all__ = [
    "ALPHA_THRESHOLD",
    "DEFAULT_FADE",
    "DEFAULT_FRAMES",
    "INPAINT_RADIUS",
    "PATCH_FILENAME",
    "build_patch",
    "character_region",
    "feather_ramp",
    "reconstruct",
    "resolve_patch_layer",
    "timeline_frames",
]
