"""
Unit tests for the layer split (`core/layers.py`).

The split is what makes the rig deform the character only, so these tests pin
its two invariants: the character layer's alpha *is* the background-removal
mask, and the background layer is the same picture with the character punched
out - which is why a pixel the character vacates ends up transparent rather
than showing its own original pixels.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.bg_removal import character_alpha
from core.errors import RigError
from core.layers import (
    LAYER_FILENAME,
    background_layer,
    composite,
    declared_character_path,
    is_split,
    layer_settings,
    load_layer,
    resolve_character_layer,
    split_layers,
    write_layer,
)


def still(size: int = 16) -> np.ndarray:
    """A flat green field with an opaque red block: a keyable still."""
    image = np.zeros((size, size, 4), dtype=np.uint8)
    image[:, :, :3] = (0, 190, 0)
    image[:, :, 3] = 255
    image[4:8, 4:8] = (0, 0, 255, 255)
    return image


# --- the character mask -----------------------------------------------------


def test_character_alpha_is_exactly_the_removed_background_mask():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)

    assert alpha.shape == source.shape[:2]
    assert set(np.unique(alpha)) <= {0, 255}
    assert (alpha[4:8, 4:8] == 255).all()  # the character survives
    assert (alpha[0:4, :] == 0).all()  # the background is keyed out


def test_character_alpha_detects_the_background_colour_from_the_frame_border():
    source = still()
    alpha = character_alpha(source, tolerance=20, soft_edges=0, edge_cleanup=0)

    # A tight tolerance around the detected border colour still keeps the block.
    assert (alpha[4:8, 4:8] == 255).all()
    assert (alpha[0:2, :] == 0).all()


# --- the split --------------------------------------------------------------


def test_split_layers_uses_the_mask_as_the_character_alpha():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, background = split_layers(source, alpha)

    assert character.shape == source.shape
    assert background.shape == source.shape

    # The character layer keeps the still's colour and takes the mask as alpha.
    assert np.array_equal(character[:, :, :3], source[:, :, :3])
    assert np.array_equal(character[:, :, 3], alpha)

    # The background layer is the same colour with the inverted mask, so the
    # character's own pixels are punched out of it.
    assert np.array_equal(background[:, :, :3], source[:, :, :3])
    assert np.array_equal(background[:, :, 3], 255 - alpha)
    assert (background[4:8, 4:8, 3] == 0).all()


def test_split_layers_rejects_a_mismatched_mask():
    source = still()
    with pytest.raises(RigError, match="does not match"):
        split_layers(source, np.zeros((4, 4), dtype=np.uint8))


def test_background_layer_inverts_the_character_alpha():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, _ = split_layers(source, alpha)

    background = background_layer(source, character)
    assert np.array_equal(background[:, :, 3], 255 - character[:, :, 3])
    assert np.array_equal(background[:, :, :3], source[:, :, :3])


# --- compositing ------------------------------------------------------------


def test_composite_puts_the_character_over_the_background():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, background = split_layers(source, alpha)

    out = composite(character, background)

    # Where the character is opaque it wins outright.
    assert np.array_equal(out[4:8, 4:8], character[4:8, 4:8])
    # Where only the background covers a pixel the background wins.
    assert np.array_equal(out[0:4, :], background[0:4, :])


def test_composite_leaves_a_vacated_pixel_transparent():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, background = split_layers(source, alpha)

    # The character moved away, so its layer no longer covers its old footprint.
    moved = character.copy()
    moved[4:8, 4:8, 3] = 0

    out = composite(moved, background)

    vacated = out[4:8, 4:8]
    assert (vacated[:, :, 3] == 0).all()
    assert not vacated[:, :, :3].any()  # and none of its original colour either


def test_composite_keeps_a_soft_edge_opaque():
    # A partition at a feathered edge: the character half-covers the pixel and
    # the background covers the other half, both carrying the still's colour.
    character = np.zeros((2, 2, 4), dtype=np.uint8)
    background = np.zeros((2, 2, 4), dtype=np.uint8)
    character[:, :, :3] = (0, 0, 255)  # BGR red
    background[:, :, :3] = (0, 0, 255)  # BGR red (the still's own colour)
    character[:, :, 3] = 128
    background[:, :, 3] = 127  # 255 - 128

    out = composite(character, background)

    # The two layers partition the still, so the feathered edge stays opaque.
    assert (out[:, :, 3] == 255).all()
    # And the still's colour is preserved exactly.
    assert (out[:, :, :3] == (0, 0, 255)).all()


def test_composite_passes_an_opaque_character_through_unchanged():
    character = np.zeros((4, 4, 4), dtype=np.uint8)
    character[:, :, :3] = (0, 0, 255)
    character[:, :, 3] = 255
    background = np.zeros((4, 4, 4), dtype=np.uint8)

    # A pixel the character fully covers has no background behind it.
    assert np.array_equal(composite(character, background), character)


def test_composite_rejects_mismatched_layers():
    source = still()
    alpha = np.zeros(source.shape[:2], dtype=np.uint8)
    character, background = split_layers(source, alpha)

    with pytest.raises(RigError, match="differ in size"):
        composite(character, background[:8])


# --- rig document accessors -------------------------------------------------


def test_layer_accessors_read_the_document():
    rig = {
        "schema": "framer.rig",
        "version": 1,
        "canvas": {"width": 8, "height": 8},
        "bones": [{"id": "b0", "rest": {"head": [0, 0], "tail": [1, 1]}}],
        "layers": {
            "split": True,
            "character": "cutout.png",
            "tolerance": 12,
            "soft_edges": 2,
            "auto_ranges": False,
            "num_ranges": 3,
        },
    }

    assert is_split(rig)
    assert declared_character_path(rig) == "cutout.png"
    settings = layer_settings(rig)
    assert settings == {
        "color": None,
        "tolerance": 12,
        "auto_ranges": False,
        "num_ranges": 3,
        "adaptive_bg": False,
        "edge_cleanup": 3,
        "soft_edges": 2,
    }


def test_layer_accessors_default_when_the_document_has_no_layers():
    rig = {"schema": "framer.rig", "version": 1}

    assert not is_split(rig)
    assert declared_character_path(rig) is None
    assert layer_settings(rig)["tolerance"] == 30


def test_a_rig_without_layers_gets_no_character_layer():
    character, written = resolve_character_layer({"layers": {"split": False}}, still(), "x.png")
    assert character is None
    assert written is None


# --- resolution / materialisation -------------------------------------------


def test_resolve_materialises_the_character_layer_beside_the_still(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    rig = {
        "layers": {"split": True, "tolerance": 40, "soft_edges": 0, "edge_cleanup": 0},
    }

    character, written = resolve_character_layer(rig, source, source_path)

    assert written == tmp_path / LAYER_FILENAME
    assert written.exists()
    # The written layer round-trips to the same pixels.
    assert np.array_equal(load_layer(written), character)
    # ...and its alpha is the background-removal mask.
    assert (character[4:8, 4:8, 3] == 255).all()
    assert (character[0:4, :, 3] == 0).all()


def test_resolve_reuses_an_existing_layer_and_reports_no_write(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    existing = tmp_path / LAYER_FILENAME
    write_layer(existing, np.zeros_like(source))

    character, written = resolve_character_layer(
        {"layers": {"split": True}}, source, source_path
    )

    assert written is None
    assert (character[:, :, 3] == 0).all()  # the file on disk, not a recompute


def test_resolve_honours_the_declared_relative_path(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    target = tmp_path / "cutouts" / "hero.png"

    _character, written = resolve_character_layer(
        {"layers": {"split": True, "character": "cutouts/hero.png", "soft_edges": 0}},
        source,
        source_path,
    )

    assert written == target
    assert target.exists()


def test_resolve_accepts_an_explicit_absolute_override(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    override = tmp_path / "elsewhere" / "hero.png"

    _character, written = resolve_character_layer(
        {"layers": {"split": True, "soft_edges": 0}},
        source,
        source_path,
        explicit=override,
    )

    assert written == override
    assert override.exists()


def test_layer_round_trips_through_disk(tmp_path):
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, _ = split_layers(source, alpha)

    path = write_layer(tmp_path / "character.png", character)
    assert np.array_equal(load_layer(path), character)
