"""
Layer split for the deform engine.

A still holds a character and a background in one picture, so a rig that
deforms the still deforms both. This module splits it into two layers and
recomposites them after the deformation, so the rig only ever warps the
character:

    source.png ── character mask (background-removal alpha) ──▶ character layer
                                                              ├─▶ background layer
                                                              └─▶ patch layer

* **character layer** - the still's colour with the mask as its alpha, so the
  cut-out is exactly the pixels the background-removal operation kept.
* **background layer** - an opaque *plate*: a full copy of the still whose
  character area is reconstructed from the surrounding background, so no pixel
  is left uncovered. It is never resampled by the rig.
* **patch layer** - a third materialised layer, between the character and the
  plate: the region the character can uncover (the union of its warped
  footprints over the timeline, minus its rest footprint) reconstructed from
  the plate, with an alpha ramp that is opaque in the middle of the region and
  fades to transparent at its edge. The feather lives here and never on the
  plate, so the frame under it stays fully opaque.

When the background layer is present, the layers are recomposited with a
plain source-over (``out = fg + bg * (1 - fg.a)``), so an opaque character wins
outright wherever it moves - even over background it did not occupy at rest -
and a pixel the character moved away from shows the reconstructed plate rather
than the character's original pixels. That is the documented fill behaviour for
a vacated region - see `docs/rig-editor.md`. When the background layer is
removed, compositing is skipped and only the deformed character layer is
rendered, preserving transparency.

The mask itself comes from the existing background-removal segmentation
(`core.bg_removal.character_alpha`); there is no second segmenter here.
"""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from core.bg_removal import character_alpha
from core.errors import RigError

# Default file names for the materialised layers, written next to the still so
# a project directory stays `source.png` + `character.png` + `background.png` +
# `patch.png` + `rig.json`.
LAYER_FILENAME = "character.png"
PLATE_FILENAME = "background.png"
PATCH_FILENAME = "patch.png"

# The default width of the patch's feather, in pixels, recorded in the rig
# document when the patch is enabled.  A rig that does not record a fade has no
# patch layer at all, so a document saved before the patch existed keeps
# rendering exactly as it did.
DEFAULT_FADE = 12

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


def composite_layers(
    character: np.ndarray,
    patch: np.ndarray | None,
    background: np.ndarray | None,
) -> np.ndarray:
    """
    Composite the layer stack: character over patch over background.

    The patch is the middle layer: it carries the feathered reconstruction of
    the region the character can uncover, and it sits *under* the character so
    the character keeps its own pixels wherever it is.  Without a patch the
    stack is the character over the background, exactly as before.
    """
    stack = character if patch is None else composite(character, patch)
    if background is None:
        return stack
    return composite(stack, background)


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


def has_character_layer(rig: dict[str, Any]) -> bool:
    """Whether the layered rig includes a character layer."""
    if not is_split(rig):
        return False
    layers = rig.get(LAYERS_KEY) or {}
    if "character" in layers:
        return layers["character"] is not False and layers["character"] is not None
    return True


def has_background_layer(rig: dict[str, Any]) -> bool:
    """Whether the layered rig includes a background layer."""
    if not is_split(rig):
        return False
    layers = rig.get(LAYERS_KEY) or {}
    if "background" in layers:
        return layers["background"] is not False and layers["background"] is not None
    return True


def declared_character_path(rig: dict[str, Any]) -> str | None:
    """The character-layer path the rig document declares, if any."""
    declared = (rig.get(LAYERS_KEY) or {}).get("character")
    return declared if isinstance(declared, str) and declared else None


def declared_background_path(rig: dict[str, Any]) -> str | None:
    """The background-layer path the rig document declares, if any."""
    declared = (rig.get(LAYERS_KEY) or {}).get("background")
    return declared if isinstance(declared, str) and declared else None


def patch_fade(rig: dict[str, Any]) -> int | None:
    """
    The feather width the rig document records, or None when it has no patch.

    The fade is what enables the patch layer: a document that records no fade
    renders exactly as it did before the patch existed, because the patch is a
    materialised layer the editor asks for explicitly.
    """
    layers = rig.get(LAYERS_KEY) or {}
    value = layers.get("fade")
    if value is None:
        return None
    return int(value)


def has_patch_layer(rig: dict[str, Any]) -> bool:
    """Whether the layered rig includes a feathered patch layer."""
    if not is_split(rig):
        return False
    return patch_fade(rig) is not None


def patch_path(source_path: str | Path) -> Path:
    """
    Where the patch layer lives: `patch.png` beside the still.

    The patch is derived from the rig and the still rather than being a file
    the user chooses, so it always has one home.
    """
    return Path(source_path).parent / PATCH_FILENAME


def resolve_background_layer(
    rig: dict[str, Any],
    source: np.ndarray,
    source_path: str | Path,
    character: np.ndarray | None,
) -> np.ndarray | None:
    """
    Return the background plate for a rig.

    The materialised plate is used when it exists, so a background layer the
    user replaced by hand is the material the frame is composited over - the
    same file the editor's preview fetches.  Otherwise the plate is rebuilt
    from the still and the character mask, exactly as
    :func:`background_plate` does.

    A rig that does not ask for a split, or whose background layer is removed,
    returns ``None``: the frame is then the character alone, with its
    transparency.
    """
    if not is_split(rig) or not has_background_layer(rig):
        return None

    declared = declared_background_path(rig) or PLATE_FILENAME
    path = Path(declared)
    if not path.is_absolute():
        path = Path(source_path).parent / path
    if path.exists():
        return load_layer(path)

    if character is None:
        return None
    return background_plate(source, character[:, :, 3])


def resolve_character_layer(
    rig: dict[str, Any],
    source: np.ndarray,
    source_path: str | Path,
) -> tuple[np.ndarray | None, Path | None]:
    """
    Return the character layer for a rig, materialising it when needed.

    The path is taken from the rig document's ``layers.character``, else the
    default ``character.png`` beside the still. A relative path is resolved
    against the still's directory, which is where the editor keeps a project's
    files.

    When the rig asks for a split but the layer file is not there yet, the
    character mask is computed from the still with the background-removal
    segmentation and both layers are written beside it (unless the background
    layer is removed) - the cut-out and the opaque plate - so a later render,
    an export and the editor's preview all read the same layers. A plate that
    predates the current cut-out is rewritten alongside it. Those writes are the
    only thing this function does beyond returning pixels.

    Returns:
        ``(character_layer, written_path)``; ``written_path`` is ``None`` when an
        existing file was reused. A rig that does not ask for a split or whose
        character layer is removed returns ``(None, None)``.
    """
    if not is_split(rig) or not has_character_layer(rig):
        return None, None

    declared = declared_character_path(rig) or LAYER_FILENAME
    path = Path(declared)
    if not path.is_absolute():
        path = Path(source_path).parent / path

    bg_declared = declared_background_path(rig) or PLATE_FILENAME
    bg_path = Path(bg_declared)
    if not bg_path.is_absolute():
        bg_path = Path(source_path).parent / bg_path

    if path.exists():
        character = load_layer(path)
        if has_background_layer(rig):
            _plate = _ensure_plate(source, character, bg_path)
        return character, None

    settings = layer_settings(rig)
    alpha = character_alpha(source, **settings)
    character, plate = split_layers(source, alpha)
    write_layer(path, character)
    if has_background_layer(rig):
        write_layer(bg_path, plate)
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
    "DEFAULT_FADE",
    "LAYERS_KEY",
    "LAYER_FILENAME",
    "PATCH_FILENAME",
    "PLATE_FILENAME",
    "background_plate",
    "character_alpha",
    "composite",
    "composite_layers",
    "declared_background_path",
    "declared_character_path",
    "has_background_layer",
    "has_character_layer",
    "has_patch_layer",
    "is_split",
    "layer_settings",
    "load_layer",
    "patch_fade",
    "patch_path",
    "resolve_background_layer",
    "resolve_character_layer",
    "split_layers",
    "write_layer",
]
