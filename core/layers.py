"""
Layer split for the deform engine.

A still holds a character and a background in one picture, so a rig that
deforms the still deforms both. This module splits it into two layers and
recomposites them after the deformation, so the rig only ever warps the
character:

    source.png ── character mask (background-removal alpha) ──▶ character layer
                                                              └─▶ background layer

* **character layer** - the still's colour with the mask as its alpha, so the
  cut-out is exactly the pixels the background-removal operation kept.
* **background layer** - an opaque *plate*: a full copy of the still whose
  character area is reconstructed from the surrounding background, so no pixel
  is left uncovered. It is never resampled by the rig.

The layers are recomposited with a plain source-over (``out = fg + bg *
(1 - fg.a)``), so an opaque character wins outright wherever it moves - even
over background it did not occupy at rest - and a pixel the character moved
away from shows the reconstructed plate rather than the character's original
pixels. That is the documented fill behaviour for a vacated region - see
`docs/rig-editor.md`.

The mask itself comes from the existing background-removal segmentation
(`core.bg_removal.character_alpha`); there is no second segmenter here.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any
import uuid

import cv2
import numpy as np

from core.bg_removal import character_alpha
from core.errors import RigError

# Default file names for the materialised layers, written next to the still so
# a project directory stays `source.png` + `character.png` + `background.png` +
# `rig.json`.
LAYER_FILENAME = "character.png"
PLATE_FILENAME = "background.png"

# The rig document field holding the layered state.
LAYERS_KEY = "layers"


def split_layers(
    source: np.ndarray,
    alpha: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Split a still into its character layer and its background plate.

    Args:
        source: BGRA still.
        alpha: ``(H, W)`` uint8 mask, ``255`` = character.

    Returns:
        ``(character, plate)`` as BGRA arrays of the same shape.
    """
    if source.ndim != 3 or source.shape[2] != 4:
        raise RigError(f"a layer split needs a BGRA still, got shape {source.shape}")

    alpha = np.asarray(alpha, dtype=np.uint8)
    if alpha.shape != source.shape[:2]:
        raise RigError(
            f"character mask shape {alpha.shape} does not match the still {source.shape[:2]}"
        )

    rgb = source[:, :, :3]
    mask = alpha[:, :, np.newaxis]
    character = np.concatenate([rgb, mask], axis=2)
    return character, background_plate(source, alpha)


def background_plate(source: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """
    The still as an opaque plate with the character area reconstructed.

    The plate is a full copy of the still - every pixel, including the ones the
    character occupied at rest - so the never-warped background layer covers
    the whole canvas. The character area is reconstructed from the surrounding
    background with the existing OpenCV inpainting, so where the character moves
    away the plate shows through instead of a hole or the character's original
    pixels.

    Args:
        source: BGRA still.
        alpha: ``(H, W)`` uint8 mask, ``255`` = character.

    Returns:
        A BGRA plate whose alpha is fully opaque.
    """
    if source.ndim != 3 or source.shape[2] != 4:
        raise RigError(f"a background plate needs a BGRA still, got shape {source.shape}")

    alpha = np.asarray(alpha, dtype=np.uint8)
    if alpha.shape != source.shape[:2]:
        raise RigError(
            f"character mask shape {alpha.shape} does not match the still {source.shape[:2]}"
        )

    plate = source[:, :, :3]
    hole = alpha > 0
    if hole.any():
        # cv2.inpaint rewrites only the masked pixels, so the untouched
        # background keeps the still's own values.
        plate = cv2.inpaint(
            plate,
            hole.astype(np.uint8) * 255,
            3,
            cv2.INPAINT_TELEA,
        )

    return np.concatenate([plate, np.full(source.shape[:2] + (1,), 255, dtype=np.uint8)], axis=2)


def composite(character: np.ndarray, background: np.ndarray) -> np.ndarray:
    """
    Composite a (already deformed) character layer over an unwarped background.

    A plain source-over: ``out_alpha = fg.a + bg.a * (1 - fg.a)`` with the
    colour weighted by each layer's coverage. An opaque character pixel wins
    outright wherever it lands - including over background it did not occupy at
    rest, which is what keeps the character from blending with the background -
    and a pixel the character vacates shows the background plate behind it.
    """
    for name, layer in (("character", character), ("background", background)):
        if layer.ndim != 3 or layer.shape[2] != 4:
            raise RigError(f"the {name} layer must be BGRA, got shape {layer.shape}")

    if character.shape != background.shape:
        raise RigError(
            f"character layer {character.shape[:2]} and background layer "
            f"{background.shape[:2]} differ in size"
        )

    fg_alpha = character[:, :, 3:4].astype(np.float32) / 255.0
    bg_alpha = background[:, :, 3:4].astype(np.float32) / 255.0

    out_alpha = fg_alpha + bg_alpha * (1.0 - fg_alpha)
    safe_alpha = np.where(out_alpha > 0.0, out_alpha, 1.0)

    colour = character[:, :, :3] * fg_alpha + background[:, :, :3] * bg_alpha * (1.0 - fg_alpha)
    colour = colour / safe_alpha

    return np.concatenate(
        [
            np.clip(colour, 0, 255).astype(np.uint8),
            np.clip(out_alpha * 255.0, 0, 255).astype(np.uint8),
        ],
        axis=2,
    )


def load_layer(path: str | Path) -> np.ndarray:
    """Read a materialised character layer as BGRA."""
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None:
        raise RigError(f"could not read character layer: {path}")

    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGRA)
    elif image.shape[2] == 3:
        alpha = np.full(image.shape[:2] + (1,), 255, dtype=np.uint8)
        image = np.concatenate([image, alpha], axis=2)
    elif image.shape[2] != 4:
        raise RigError(f"unsupported character layer shape: {image.shape}")

    return np.ascontiguousarray(image)


def write_layer(path: str | Path, layer: np.ndarray) -> Path:
    """Write a character layer as a PNG and return its path."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_name(f".{target.name}.tmp.{uuid.uuid4().hex}.png")
    if not cv2.imwrite(str(temp), layer):
        if temp.exists():
            temp.unlink()
        raise RigError(f"could not write character layer to {target}")
    temp.replace(target)
    return target


def layer_settings(rig: dict[str, Any]) -> dict[str, Any]:
    """The character-mask settings recorded on the rig document."""
    layers = rig.get(LAYERS_KEY) or {}

    def _get(key: str, default: Any, cast: Any) -> Any:
        v = layers.get(key)
        return default if v is None else cast(v)

    return {
        "color": layers.get("color"),
        "tolerance": _get("tolerance", 30, int),
        "auto_ranges": _get("auto_ranges", True, bool),
        "num_ranges": _get("num_ranges", 5, int),
        "adaptive_bg": _get("adaptive_bg", False, bool),
        "edge_cleanup": _get("edge_cleanup", 0, int),
        "soft_edges": _get("soft_edges", 0, int),
    }


def is_split(rig: dict[str, Any]) -> bool:
    """Whether the rig document asks for a layered render."""
    return bool((rig.get(LAYERS_KEY) or {}).get("split", False))


def declared_character_path(rig: dict[str, Any]) -> str | None:
    """The character-layer path the rig document declares, if any."""
    declared = (rig.get(LAYERS_KEY) or {}).get("character")
    return declared if isinstance(declared, str) and declared else None


def resolve_character_layer(
    rig: dict[str, Any],
    source: np.ndarray,
    source_path: str | Path,
) -> tuple[np.ndarray, Path | None]:
    """
    Return the character layer for a rig, materialising it when needed.

    The path is taken from the rig document's ``layers.character``, else the
    default ``character.png`` beside the still. A relative path is resolved
    against the still's directory, which is where the editor keeps a project's
    files.

    When the rig asks for a split but the layer file is not there yet, the
    character mask is computed from the still with the background-removal
    segmentation and both layers are written beside it - the cut-out and the
    opaque plate - so a later render, an export and the editor's preview all
    read the same two layers. A plate that predates the current cut-out is
    rewritten alongside it. Those writes are the only thing this function does
    beyond returning pixels.

    Returns:
        ``(character_layer, written_path)``; ``written_path`` is ``None`` when an
        existing file was reused. A rig that does not ask for a split returns
        ``(None, None)``.
    """
    if not is_split(rig):
        return None, None

    declared = declared_character_path(rig) or LAYER_FILENAME
    path = Path(declared)
    if not path.is_absolute():
        path = Path(source_path).parent / path

    if path.exists():
        character = load_layer(path)
        _plate = _ensure_plate(source, character, Path(source_path).parent / PLATE_FILENAME)
        return character, None

    settings = layer_settings(rig)
    alpha = character_alpha(source, **settings)
    character, plate = split_layers(source, alpha)
    write_layer(path, character)
    write_layer(Path(source_path).parent / PLATE_FILENAME, plate)
    return character, path


def _ensure_plate(
    source: np.ndarray,
    character: np.ndarray,
    plate_path: Path,
) -> Path:
    """
    Write the plate for an existing character layer when it is missing.

    A project folder that already holds a cut-out from before the plate existed
    has no background layer yet, and the editor's preview needs the same file
    the engine composites with - so it is materialised on demand from the
    cut-out's own alpha, which is the mask it was built with.
    """
    if not plate_path.exists():
        plate = background_plate(source, character[:, :, 3])
        write_layer(plate_path, plate)
    return plate_path


__all__ = [
    "LAYERS_KEY",
    "LAYER_FILENAME",
    "PLATE_FILENAME",
    "background_plate",
    "character_alpha",
    "composite",
    "declared_character_path",
    "is_split",
    "layer_settings",
    "load_layer",
    "resolve_character_layer",
    "split_layers",
    "write_layer",
]
