"""
The healing brush: hand-painted corrections to the background plate.

The automatic patch (`core/patch.py`) reconstructs the ground the character
uncovers from the surrounding background and feathers it into the untouched
plate.  Sometimes that reconstruction is not good enough - a texture the
inpainting could not invent, an edge it smeared - and the user repairs the
area by hand.

The brush is the same kind of fix, done by hand:

* the user paints over the bad area;
* the surrounding background is painted over it, by the very same
  reconstruction the automatic patch uses (`core.patch.reconstruct`);
* the correction merges into the untouched background with the very same
  falloff (`core.patch.feather_ramp`) - the alpha ramp that is opaque in the
  middle of the area and transparent at its edge.  The ramp is measured from
  the area the user painted, not from the rig's absolute feather width: the
  correction is fully opaque across the painted area's middle, so the pixels
  the user covered are actually replaced, and it feathers into the untouched
  background at the edge of the painted area, never as a hard-edged blob.

So a hand-painted correction is not a blob pasted on top of the plate: it
behaves exactly like the patch the engine builds, and the plate stays fully
opaque underneath it.

Every correction is also *material*: the content that was painted, the mask it
covered and the pixels it replaced.  Those three are what a later model would
be trained on, so `heal_brush` returns them next to the healed plate and
`heal_file` writes them out, and the editor stores them the moment the brush
is used.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from core.errors import RigError
from core.layers import DEFAULT_FADE, write_layer
from core.patch import feather_ramp, reconstruct, region_radius

# The radius of the round brush, in pixels, when a stroke does not name one.
DEFAULT_BRUSH_RADIUS = 12

# The narrowest falloff band a manual correction may have, in pixels.  A
# correction is never a hard-edged blob, so the band is never zero, whatever
# the rig's own feather says.
MIN_BAND = 3

# The inpaint radius for the reconstruction.  The same width the automatic
# patch uses, so a hand-painted correction is synthesised exactly like the
# patch it joins.
INPAINT_RADIUS = 5

# The names the three training artefacts are written under.
CONTENT_FILENAME = "content.png"
MASK_FILENAME = "mask.png"
REPLACED_FILENAME = "replaced.png"

# The sidecar that records what the correction was: the rectangle the three
# artefacts are cropped to, and the falloff it was feathered with.  The editor
# reads it to store the correction, so the store knows the geometry without
# having to look at the pixels.
META_FILENAME = "correction.json"


def _as_points(stroke: Any) -> list[tuple[float, float]]:
    """The points of one stroke, as floats."""
    points = stroke.get("points") if isinstance(stroke, dict) else stroke
    result: list[tuple[float, float]] = []
    for point in points or []:
        if isinstance(point, dict):
            x, y = point.get("x"), point.get("y")
        else:
            try:
                x, y = point[0], point[1]
            except (TypeError, IndexError):
                continue
        if isinstance(x, (int, float)) and isinstance(y, (int, float)):
            result.append((float(x), float(y)))
    return result


def stroke_radius(stroke: Any, default: int = DEFAULT_BRUSH_RADIUS) -> int:
    """The radius of one stroke, in pixels."""
    if isinstance(stroke, dict):
        radius = stroke.get("radius")
        if isinstance(radius, (int, float)) and radius > 0:
            return round(radius)
    return default


def stroke_mask(
    shape: tuple[int, ...],
    strokes: Iterable[Any],
    radius: int = DEFAULT_BRUSH_RADIUS,
) -> np.ndarray:
    """
    The area the brush covered: the union of the strokes' round brushes.

    The mask is the *painted* area - what the user covered - and it is the
    area the correction is feathered over, so the ramp starts at its edge.
    """
    height, width = shape[0], shape[1]
    mask = np.zeros((height, width), np.uint8)

    for stroke in strokes or []:
        brush = stroke_radius(stroke, radius)
        for x, y in _as_points(stroke):
            cv2.circle(
                mask,
                (round(x), round(y)),
                max(brush, 1),
                255,
                -1,
                lineType=cv2.LINE_8,
            )

    return mask


def correction_band(mask: np.ndarray, fade: int) -> int:
    """
    The width of the falloff band of a manual correction, in pixels.

    The ramp is the patch's own ramp, so a correction merges into the
    untouched background exactly like the automatic patch does - but it is
    measured from the area the user painted, not from the rig's absolute
    feather width.  A brush-sized area is smaller than the feather the rig
    records, so the band is scaled down to what the painted area can carry:
    the correction is fully opaque across its middle and only its edge
    feathers into the background.

    The band is never zero: a rig with no feather of its own still gets a
    correction with a soft edge, never a hard-edged blob.
    """
    radius = region_radius(mask)
    # The widest band that still leaves the painted area opaque across its
    # middle: the ramp reaches full opacity half way into the area.
    limit = max(1, int(radius) // 2)

    if fade <= 0:
        return max(1, min(MIN_BAND, limit))
    return max(1, min(int(fade), limit))


def heal_plate(
    plate: np.ndarray,
    strokes: Iterable[Any],
    *,
    fade: int = DEFAULT_FADE,
    radius: int = DEFAULT_BRUSH_RADIUS,
) -> dict[str, Any]:
    """
    Paint the surrounding background over the area the brush covered.

    The reconstruction is the automatic patch's own: the painted area is
    filled from the background around it, so the character's own pixels never
    bleed into the correction.  The falloff is the patch's own alpha ramp, so
    the correction merges into the untouched background instead of sitting on
    it as a hard-edged blob.

    Args:
        plate: the background plate, BGRA.
        strokes: the strokes the user painted.
        fade: the width of the feather the rig records, in pixels.
        radius: the brush radius for strokes that do not name one.

    Returns:
        A map with:

        * ``plate`` - the healed plate, BGRA and fully opaque.
        * ``mask`` - the painted area, ``(H, W)`` uint8.
        * ``content`` - what was painted: the reconstructed area, BGRA.
        * ``replaced`` - what it replaced: the plate's own pixels there, BGRA.
        * ``bbox`` - the rectangle the correction covers, as
          ``(x, y, width, height)``.
        * ``band`` - the width of the falloff band, in pixels.
    """
    if plate.ndim != 3 or plate.shape[2] != 4:
        raise RigError(f"the healing brush needs a BGRA plate, got shape {plate.shape}")

    mask = stroke_mask(plate.shape, strokes, radius)
    if mask.max() == 0:
        raise RigError("the healing brush needs at least one painted point")

    # The very same ramp the automatic patch feathers with: opaque in the
    # middle of the area, transparent at its edge - measured from the area
    # the user painted, so the correction is opaque where they painted.
    band = correction_band(mask, fade)
    ramp = feather_ramp(mask, band)
    alpha = (ramp.astype(np.float32) / 255.0)[:, :, np.newaxis]

    bgr = plate[:, :, :3]
    content_bgr = reconstruct(plate, mask, INPAINT_RADIUS)
    content = np.concatenate(
        [content_bgr, np.full(plate.shape[:2] + (1,), 255, dtype=np.uint8)], axis=2
    )

    healed = bgr.astype(np.float32) * (1.0 - alpha) + content_bgr.astype(np.float32) * alpha
    healed = np.clip(healed, 0, 255).astype(np.uint8)
    healed = np.concatenate(
        [healed, np.full(plate.shape[:2] + (1,), 255, dtype=np.uint8)], axis=2
    )

    return {
        "plate": healed,
        "mask": mask,
        "content": content,
        "replaced": plate.copy(),
        "bbox": mask_bbox(mask),
        "band": band,
    }


def mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    """
    The rectangle a mask covers, as ``(x, y, width, height)``.

    The training artefacts are cropped to it, so a correction costs a few
    kilobytes instead of a whole frame - and the crop is the same rectangle
    for the content, the mask and the replaced pixels, so the three line up.
    """
    ys, xs = np.nonzero(mask)
    if xs.size == 0:
        return (0, 0, 0, 0)
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()), int(ys.max())
    return (x0, y0, x1 - x0 + 1, y1 - y0 + 1)


def crop(image: np.ndarray, bbox: tuple[int, int, int, int]) -> np.ndarray:
    """Crop an image to a ``(x, y, width, height)`` rectangle."""
    x, y, width, height = bbox
    return image[y : y + height, x : x + width]


def heal_file(
    plate_path: str | Path,
    strokes: Iterable[Any],
    *,
    target_path: str | Path,
    artifacts_dir: str | Path,
    fade: int = DEFAULT_FADE,
    radius: int = DEFAULT_BRUSH_RADIUS,
    canvas: tuple[int, int] | None = None,
) -> dict[str, Any]:
    """
    Heal a plate on disk and write the training artefacts beside it.

    The three artefacts - the content that was painted, the mask it covered
    and the pixels it replaced - are written as PNGs, cropped to the painted
    rectangle, so the editor can store them the moment the brush is used.

    The strokes are painted in the canvas's own pixels, and the plate the
    editor shows is fitted to the canvas, so the plate is fitted to the
    canvas too before it is healed: the correction then lands exactly where
    the user painted it, and the rectangle the artefacts are cropped to is a
    rectangle in canvas pixels.

    Args:
        plate_path: the background plate to heal.
        strokes: the strokes the user painted, in canvas pixels.
        target_path: where the healed plate is written.
        artifacts_dir: where the training artefacts are written.
        fade: the width of the feather the rig records, in pixels.
        radius: the brush radius for strokes that do not name one.
        canvas: the canvas size, as ``(width, height)``.

    Returns:
        A map with the healed plate's path, the artefacts' paths and the
        rectangle they are cropped to.
    """
    plate = cv2.imread(str(plate_path), cv2.IMREAD_UNCHANGED)
    if plate is None:
        raise RigError(f"could not read the background plate: {plate_path}")
    if plate.ndim == 3 and plate.shape[2] == 3:
        plate = np.concatenate(
            [plate, np.full(plate.shape[:2] + (1,), 255, dtype=np.uint8)], axis=2
        )

    if canvas is not None:
        width, height = int(canvas[0]), int(canvas[1])
        if width > 0 and height > 0 and (plate.shape[1], plate.shape[0]) != (width, height):
            plate = cv2.resize(plate, (width, height), interpolation=cv2.INTER_LINEAR)

    result = heal_plate(plate, strokes, fade=fade, radius=radius)
    bbox = result["bbox"]
    band = result["band"]

    artifacts = Path(artifacts_dir)
    artifacts.mkdir(parents=True, exist_ok=True)

    content_path = artifacts / CONTENT_FILENAME
    mask_path = artifacts / MASK_FILENAME
    replaced_path = artifacts / REPLACED_FILENAME

    write_layer(content_path, crop(result["content"], bbox))
    if not cv2.imwrite(str(mask_path), crop(result["mask"], bbox)):
        raise RigError(f"could not write the correction mask to {mask_path}")
    write_layer(replaced_path, crop(result["replaced"], bbox))

    target = Path(target_path)
    write_layer(target, result["plate"])

    meta = {
        "bbox": {"x": bbox[0], "y": bbox[1], "width": bbox[2], "height": bbox[3]},
        "fade": band,
        "radius": radius,
    }
    meta_path = artifacts / META_FILENAME
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")

    return {
        "plate": str(target),
        "content": str(content_path),
        "mask": str(mask_path),
        "replaced": str(replaced_path),
        "meta": str(meta_path),
        "bbox": meta["bbox"],
        "fade": band,
    }


def read_strokes(path: str | Path) -> list[dict[str, Any]]:
    """
    Read the strokes of a correction from a JSON file.

    The editor writes the strokes the user painted next to the project, so
    the Port worker is handed a path rather than the geometry itself.
    """
    payload = json.loads(Path(path).read_text())
    strokes = payload.get("strokes") if isinstance(payload, dict) else payload
    if not isinstance(strokes, list):
        raise RigError("the stroke file must hold a list of strokes")
    return strokes


__all__ = [
    "CONTENT_FILENAME",
    "DEFAULT_BRUSH_RADIUS",
    "DEFAULT_FADE",
    "INPAINT_RADIUS",
    "MASK_FILENAME",
    "META_FILENAME",
    "MIN_BAND",
    "REPLACED_FILENAME",
    "correction_band",
    "crop",
    "heal_file",
    "heal_plate",
    "mask_bbox",
    "read_strokes",
    "stroke_mask",
    "stroke_radius",
]
