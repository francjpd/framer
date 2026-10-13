"""
Unit tests for the layer split (`core/layers.py`).

The split is what makes the rig deform the character only, so these tests pin
its invariants: the character layer's alpha *is* the background-removal mask,
the background layer is an opaque plate - the still with the character area
reconstructed - and the composite is a plain source-over, so an opaque
character wins wherever it moves and a vacated pixel shows the plate rather than
the character's original pixels.
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
    PLATE_FILENAME,
    background_plate,
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
    character, plate = split_layers(source, alpha)

    assert character.shape == source.shape
    assert plate.shape == source.shape

    # The character layer keeps the still's colour and takes the mask as alpha.
    assert np.array_equal(character[:, :, :3], source[:, :, :3])
    assert np.array_equal(character[:, :, 3], alpha)

    # The plate is opaque everywhere, including the character's footprint.
    assert (plate[:, :, 3] == 255).all()


def test_split_layers_rejects_a_mismatched_mask():
    source = still()
    with pytest.raises(RigError, match="does not match"):
        split_layers(source, np.zeros((4, 4), dtype=np.uint8))


def test_the_plate_reconstructs_the_character_area():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)

    plate = background_plate(source, alpha)

    # The plate is a full copy of the still, so the untouched background is
    # byte-identical to the source's own pixels.
    background_only = alpha == 0
    assert np.array_equal(plate[background_only, :3], source[background_only, :3])

    # ...and the character area carries no character pixel any more: it is
    # reconstructed from the surrounding flat green field.
    character_only = alpha == 255
    character_pixels = plate[character_only, :3]
    assert not (character_pixels == (0, 0, 255)).all(axis=1).any()
    assert (character_pixels[:, 1] > character_pixels[:, 0]).all()
    assert (character_pixels[:, 1] > character_pixels[:, 2]).all()


def test_the_plate_of_an_untouched_still_is_the_still_itself():
    source = still()

    plate = background_plate(source, np.zeros(source.shape[:2], dtype=np.uint8))

    assert np.array_equal(plate, source)


# --- compositing ------------------------------------------------------------


def test_composite_puts_the_character_over_the_background():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, plate = split_layers(source, alpha)

    out = composite(character, plate)

    # Where the character is opaque it wins outright.
    assert np.array_equal(out[4:8, 4:8], character[4:8, 4:8])
    # Where only the background covers a pixel the plate wins.
    assert np.array_equal(out[0:4, :, :3], plate[0:4, :, :3])


def test_composite_does_not_blend_the_character_into_the_plate():
    # The core scenario: the character has warped over background it did not
    # occupy at rest, so both layers are opaque there. A weighted average would
    # render the character as a ~50% washout; source-over keeps it solid.
    character = np.zeros((4, 4, 4), dtype=np.uint8)
    plate = np.zeros((4, 4, 4), dtype=np.uint8)
    character[:, :, :3] = (0, 0, 255)  # BGR red
    character[:, :, 3] = 255
    plate[:, :, :3] = (0, 190, 0)  # BGR green
    plate[:, :, 3] = 255

    out = composite(character, plate)

    assert (out[:, :, 3] == 255).all()
    assert (out[:, :, :3] == (0, 0, 255)).all()


def test_composite_shows_the_plate_where_the_character_moved_away():
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, plate = split_layers(source, alpha)

    # The character moved on, so its layer no longer covers its old footprint.
    moved = character.copy()
    moved[4:8, 4:8, 3] = 0

    out = composite(moved, plate)

    vacated = out[4:8, 4:8]
    # The vacated region is opaque and shows the reconstructed plate, never the
    # character's original pixels and never a see-through hole.
    assert (vacated[:, :, 3] == 255).all()
    assert not (vacated[:, :, :3] == (0, 0, 255)).all(axis=2).any()
    assert (vacated[:, :, 1] > vacated[:, :, 2]).all()


def test_composite_keeps_a_half_covered_character_edge_opaque():
    # A feathered edge: the character layer half-covers the pixel, and the
    # opaque plate carries the still's own background colour behind it.
    character = np.zeros((2, 2, 4), dtype=np.uint8)
    plate = np.zeros((2, 2, 4), dtype=np.uint8)
    character[:, :, :3] = (0, 0, 255)  # BGR red
    character[:, :, 3] = 128
    plate[:, :, :3] = (0, 190, 0)  # BGR green
    plate[:, :, 3] = 255

    out = composite(character, plate)

    # Opaque, and half character over half plate.
    assert (out[:, :, 3] == 255).all()
    assert np.array_equal(out[:, :, :3], np.full((2, 2, 3), (0, 94, 128), dtype=np.uint8))


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
    character, plate = split_layers(source, alpha)

    with pytest.raises(RigError, match="differ in size"):
        composite(character, plate[:8])


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
        "edge_cleanup": 0,
        "soft_edges": 2,
    }


def test_layer_accessors_default_when_the_document_has_no_layers():
    rig = {"schema": "framer.rig", "version": 1}

    assert not is_split(rig)
    assert declared_character_path(rig) is None
    assert layer_settings(rig)["tolerance"] == 30


def test_layer_accessors_default_to_an_exact_mask():
    # The editor records no feathering or cleanup, so the recorded split mask
    # is the segmentation's own and carries no background into the character
    # layer and none of the character rim into the plate.
    rig = {"layers": {"split": True}}

    settings = layer_settings(rig)

    assert settings["edge_cleanup"] == 0
    assert settings["soft_edges"] == 0


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


def test_resolve_materialises_the_plate_next_to_the_cut_out(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    rig = {
        "layers": {"split": True, "tolerance": 40, "soft_edges": 0, "edge_cleanup": 0},
    }

    resolve_character_layer(rig, source, source_path)

    plate = tmp_path / PLATE_FILENAME
    assert plate.exists()
    written_plate = load_layer(plate)
    # Opaque everywhere, including the character's footprint.
    assert (written_plate[:, :, 3] == 255).all()
    # And it agrees with a plate built from the cut-out's own alpha.
    character = load_layer(tmp_path / LAYER_FILENAME)
    assert np.array_equal(written_plate, background_plate(source, character[:, :, 3]))


def test_resolve_reuses_an_existing_layer_and_reports_no_write(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    existing = tmp_path / LAYER_FILENAME
    write_layer(existing, np.zeros_like(source))

    character, written = resolve_character_layer({"layers": {"split": True}}, source, source_path)

    assert written is None
    assert (character[:, :, 3] == 0).all()  # the file on disk, not a recompute


def test_resolve_backfills_a_missing_plate_for_an_existing_cut_out(tmp_path):
    source = still()
    source_path = tmp_path / "source.png"
    existing = tmp_path / LAYER_FILENAME
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, _ = split_layers(source, alpha)
    write_layer(existing, character)

    assert not (tmp_path / PLATE_FILENAME).exists()

    resolve_character_layer({"layers": {"split": True}}, source, source_path)

    # A project that already holds a cut-out gets the plate it was missing, so
    # the editor's preview has the same background the engine composites with.
    assert (tmp_path / PLATE_FILENAME).exists()
    assert np.array_equal(load_layer(tmp_path / PLATE_FILENAME), background_plate(source, alpha))


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
    # The plate keeps its conventional name beside the still, so the editor
    # resolves it without a second declared path.
    assert (tmp_path / PLATE_FILENAME).exists()


def test_layer_round_trips_through_disk(tmp_path):
    source = still()
    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, _ = split_layers(source, alpha)

    path = write_layer(tmp_path / "character.png", character)
    assert np.array_equal(load_layer(path), character)
