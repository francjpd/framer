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
* **background layer** - the still's colour with the *inverse* of the mask as
  its alpha, i.e. the same picture with the character punched out. It is never
  resampled by the rig.

The layers are recomposited additively (out_alpha = fg + bg, colour weighted by
coverage), so a pixel the character moved away from ends up transparent: the
character layer no longer covers it and the background layer has no colour there
either. That is the documented fill behaviour for a vacated region - see
`docs/rig-editor.md`.

The mask itself comes from the existing background-removal segmentation
(`core.bg_removal.character_alpha`); there is no second segmenter here.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2
import numpy as np

from core.bg_removal import character_alpha
from core.errors import RigError

# Default file name for the materialised character layer, written next to the
# still so a project directory stays `source.png` + `character.png` + `rig.json`.
LAYER_FILENAME = "character.png"

# The rig document field holding the layered state.
LAYERS_KEY = "layers"


def split_layers(
    source: np.ndarray,
    alpha: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Split a still into its character and background layers.

    Args:
        source: BGRA still.
        alpha: ``(H, W)`` uint8 mask, ``255`` = character.

    Returns:
        ``(character, background)`` as BGRA arrays of the same shape.
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
    background = np.concatenate([rgb, 255 - mask], axis=2)
    return character, background


def composite(character: np.ndarray, background: np.ndarray) -> np.ndarray:
    """
    Composite a (already deformed) character layer over an unwarped background.

    The two layers partition the still (the background's alpha is the inverse
    of the character's mask), so the composite is additive: ``out_alpha = fg +
    bg`` with the colour weighted by each layer's coverage and divided by the
    sum. That keeps a feathered edge opaque - a pixel the character half-covers
    is half-covered by the background too - and leaves a pixel neither layer
    covers (the vacated region) transparent.
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

    out_alpha = fg_alpha + bg_alpha
    safe_alpha = np.where(out_alpha > 0.0, out_alpha, 1.0)

    colour = character[:, :, :3] * fg_alpha + background[:, :, :3] * bg_alpha
    colour = colour / safe_alpha

    return np.concatenate(
        [
            np.clip(colour, 0, 255).astype(np.uint8),
            np.clip(out_alpha * 255.0, 0, 255).astype(np.uint8),
        ],
        axis=2,
    )


def background_layer(source: np.ndarray, character: np.ndarray) -> np.ndarray:
    """The still's colour with the character layer punched out (its alpha inverted)."""
    if character.shape[:2] != source.shape[:2]:
        raise RigError(
            f"character layer {character.shape[:2]} does not match the still {source.shape[:2]}"
        )
    inverse = 255 - character[:, :, 3:4]
    return np.concatenate([source[:, :, :3], inverse], axis=2)


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
    if not cv2.imwrite(str(target), layer):
        raise RigError(f"could not write character layer to {target}")
    return target


def layer_settings(rig: dict[str, Any]) -> dict[str, Any]:
    """The character-mask settings recorded on the rig document."""
    layers = rig.get(LAYERS_KEY) or {}
    return {
        "color": layers.get("color"),
        "tolerance": int(layers.get("tolerance", 30)),
        "auto_ranges": bool(layers.get("auto_ranges", True)),
        "num_ranges": int(layers.get("num_ranges", 5)),
        "adaptive_bg": bool(layers.get("adaptive_bg", False)),
        "edge_cleanup": int(layers.get("edge_cleanup", 3)),
        "soft_edges": int(layers.get("soft_edges", 5)),
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
    explicit: str | Path | None = None,
) -> tuple[np.ndarray, Path | None]:
    """
    Return the character layer for a rig, materialising it when needed.

    The declared path is taken from ``explicit`` (an operation option), else
    from the rig document's ``layers.character``, else the default
    ``character.png`` beside the still. A relative path is resolved against the
    still's directory, which is where the editor keeps a project's files.

    When the rig asks for a split but the layer file is not there yet, the
    character mask is computed from the still with the background-removal
    segmentation and written to that path, so a later render, an export and the
    editor's preview all read the same cut-out. That write is the only thing
    this function does beyond returning pixels.

    Returns:
        ``(character_layer, written_path)``; ``written_path`` is ``None`` when an
        existing file was reused. A rig that does not ask for a split returns
        ``(None, None)``.
    """
    if not is_split(rig):
        return None, None

    declared = str(explicit) if explicit else (declared_character_path(rig) or LAYER_FILENAME)
    path = Path(declared)
    if not path.is_absolute():
        path = Path(source_path).parent / path

    if path.exists():
        return load_layer(path), None

    settings = layer_settings(rig)
    alpha = character_alpha(source, **settings)
    character, _background = split_layers(source, alpha)
    return character, write_layer(path, character)


__all__ = [
    "LAYERS_KEY",
    "LAYER_FILENAME",
    "background_layer",
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
