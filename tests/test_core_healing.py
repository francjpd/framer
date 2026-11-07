"""
Proof: the healing brush repairs the background layer the way the patch does.

The automatic patch reconstructs the ground the character uncovers from the
surrounding background and feathers it into the untouched plate.  The healing
brush is the hand-painted version of the very same fix, so it has to behave
the same way: the surrounding background is painted over the bad area, and the
correction merges into the untouched background with the patch's own falloff -
never as a hard-edged blob.

What is pinned:

1. **The bad area is repaired.** The painted area is filled from the
   surrounding background, so the artefact the user painted over is gone.
2. **The correction is opaque where the user painted.** The falloff is the
   patch's own ramp, but it is measured from the area the user painted, so
   the pixels they covered are replaced outright - a brush-sized area is
   smaller than the feather the rig records, and the feather may not swallow
   the whole correction.
3. **There is no hard edge.** The transition from the untouched background
   into the correction is gradual, and the background outside the painted area
   is byte-for-byte untouched.  A rig with no feather of its own still gets a
   soft edge.
4. **The plate stays opaque.** The feather lives on the correction, never as a
   hole in the plate.
5. **The correction lands where the user painted.** The strokes are painted
   in the canvas's own pixels, and the plate is fitted to the canvas before
   it is healed, so a plate that is not the canvas's size is still corrected
   in the right place.
6. **The correction is material.** The content that was painted, the mask it
   covered and the pixels it replaced are written out, cropped to the painted
   rectangle - the training material, stored from the first use.
7. **The patch shows the correction.** The patch is the ground the character
   uncovers; a correction painted into that ground is what the frame shows,
   and it is still what the frame shows after the patch is rebuilt.
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.bg_removal import character_alpha
from core.deform import load_or_build_weights
from core.healing import (
    CONTENT_FILENAME,
    MASK_FILENAME,
    MIN_BAND,
    REPLACED_FILENAME,
    correction_band,
    heal_file,
    heal_plate,
    read_strokes,
    stroke_mask,
)
from core.layers import split_layers, write_layer
from core.patch import (
    apply_corrections,
    build_patch,
    character_region,
    corrections_path,
    feather_ramp,
    load_corrections,
    resolve_patch_layer,
)
from ops.deform import deform_video

SIZE = 64
FADE = 12
BRUSH = 20

# The artefact the user paints over: a red block in the middle of the plate.
BAD_ROWS = slice(24, 40)
BAD_COLUMNS = slice(24, 40)


def make_plate() -> np.ndarray:
    """A plate with a textured green ground and a red artefact in the middle."""
    plate = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    band = 190 + (np.arange(SIZE) % 3)
    plate[:, :, 1] = band[None, :]
    plate[:, :, 3] = 255
    plate[BAD_ROWS, BAD_COLUMNS] = (0, 0, 255, 255)
    return plate


def stroke() -> list[dict]:
    """One stroke over the artefact, wide enough to reach the good ground."""
    return [{"points": [[32, 32]], "radius": BRUSH}]


def opaque_core(mask: np.ndarray, band: int) -> np.ndarray:
    """The pixels the correction is fully opaque on: the painted middle."""
    distance = cv2.distanceTransform((mask > 0).astype(np.uint8), cv2.DIST_L2, 3)
    return (distance >= band + 1) & (mask > 0)


def test_the_painted_area_is_repaired() -> None:
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    healed = result["plate"]
    centre = healed[32, 32]

    # The red artefact is gone: the middle of the painted area now carries the
    # surrounding green ground.
    assert centre[2] < 40, "the artefact is still red after healing"
    assert centre[1] > 150, "the surrounding background was not painted over it"


def test_the_untouched_background_is_untouched() -> None:
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    healed = result["plate"]

    # Far outside the painted disc the correction cannot reach, so those
    # pixels are byte-for-byte what they were.
    assert np.array_equal(healed[0:8, 0:8], plate[0:8, 0:8])
    assert np.array_equal(healed[56:64, 56:64], plate[56:64, 56:64])


def test_the_correction_is_opaque_where_the_user_painted() -> None:
    """The painted pixels are replaced outright, not tinted."""
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    mask = result["mask"]
    content = result["content"]
    healed = result["plate"]
    band = result["band"]

    # The middle of the painted area is the painted content at full
    # strength: the artefact the user covered is gone, not merely faded.
    core = opaque_core(mask, band)
    ys, xs = np.nonzero(core)
    assert len(ys) > 0
    assert np.array_equal(healed[ys, xs, :3], content[ys, xs, :3])


def test_the_falloff_is_measured_from_the_painted_area() -> None:
    """The rig's feather shapes the edge, but it cannot swallow the brush."""
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    band = result["band"]
    mask = result["mask"]

    # The band is the rig's own feather: the painted area is bigger than it,
    # so it is not scaled down.
    assert band == FADE
    assert band == correction_band((SIZE, SIZE), stroke(), FADE, BRUSH)

    # The ramp is the patch's own ramp over that band.
    ramp = feather_ramp(mask, band)
    assert (ramp[mask == 0] == 0).all()
    assert ramp.max() == 255
    # The middle of the painted area is fully opaque.
    core = opaque_core(mask, band)
    assert (ramp[core] == 255).all()


def test_a_brush_smaller_than_the_feather_is_opaque_inside() -> None:
    """A small brush with the rig's big feather is still a full correction."""
    plate = make_plate()
    small = [{"points": [[32, 32]], "radius": 4}]
    result = heal_plate(plate, small, fade=FADE, radius=4)

    mask = result["mask"]
    band = result["band"]
    assert band < FADE, "the feather was not scaled down to the painted area"

    core = opaque_core(mask, band)
    ys, xs = np.nonzero(core)
    assert len(ys) > 0
    assert np.array_equal(result["plate"][ys, xs, :3], result["content"][ys, xs, :3])


def test_a_narrow_stroke_stays_opaque_beside_a_wide_one() -> None:
    """One correction can hold brushes of different widths: both stay opaque."""
    plate = make_plate()
    wide = {"points": [[12, 12]], "radius": 20}
    narrow = {"points": [[32, 32]], "radius": 4}
    result = heal_plate(plate, [wide, narrow], fade=FADE, radius=BRUSH)

    mask = result["mask"]
    band = result["band"]

    # The narrow brush sizes the band: a band sized by the wide brush would
    # leave most of the narrow stroke inside the feather.
    assert band < FADE

    for stroke in (wide, narrow):
        core = opaque_core(stroke_mask((SIZE, SIZE), [stroke], BRUSH), band)
        ys, xs = np.nonzero(core)
        assert len(ys) > 0, "the stroke has no fully opaque middle"
        assert (mask[ys, xs] > 0).all()
        assert np.array_equal(
            result["plate"][ys, xs, :3], result["content"][ys, xs, :3]
        ), "the painted pixels were only tinted, not replaced"


def test_a_rig_without_a_feather_still_softens_the_edge() -> None:
    """A rig with no feather of its own still gets a soft-edged correction."""
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=0, radius=BRUSH)

    mask = result["mask"]
    band = result["band"]

    # The band is never zero: a correction is never a hard-edged blob.
    assert band == MIN_BAND
    assert band >= 1

    # The edge is a gradient, not a step: the ramp has values in between.
    ramp = feather_ramp(mask, band)
    middle = ramp[(ramp > 0) & (ramp < 255)]
    assert middle.size > 0, "the correction was pasted on with a hard edge"

    # And the painted area is still fully replaced in its middle.
    core = opaque_core(mask, band)
    ys, xs = np.nonzero(core)
    assert len(ys) > 0
    assert np.array_equal(result["plate"][ys, xs, :3], result["content"][ys, xs, :3])


def test_the_correction_merges_into_the_untouched_background() -> None:
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    healed = result["plate"]
    mask = result["mask"]
    content = result["content"]

    kernel = np.ones((3, 3), np.uint8)

    # The very edge of the painted area: the correction is transparent there,
    # so the pixels are exactly the background the brush never reached. A
    # hard-edged blob would show the correction's own colour instead.
    edge = (mask > 0) & (cv2.erode(mask, kernel) == 0)
    ys, xs = np.nonzero(edge)
    assert len(ys) > 0
    edge_delta = np.abs(
        healed[ys, xs, :3].astype(int) - plate[ys, xs, :3].astype(int)
    ).max()
    assert edge_delta <= 12, "the correction was pasted on with a hard edge"

    # The middle of the painted area: the correction is fully opaque there, so
    # those pixels are the painted content and nothing else.
    core = opaque_core(mask, result["band"])
    ys, xs = np.nonzero(core)
    assert len(ys) > 0
    assert np.array_equal(healed[ys, xs, :3], content[ys, xs, :3])


def test_the_plate_stays_opaque() -> None:
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    assert (result["plate"][:, :, 3] == 255).all()


def test_the_correction_lands_where_the_user_painted(tmp_path: Path) -> None:
    """The strokes are canvas pixels: they are mapped into the plate's."""
    # A plate that is not the canvas's size: the user replaced the
    # background with an image of another resolution.
    plate = cv2.resize(make_plate(), (SIZE * 2, SIZE * 2), interpolation=cv2.INTER_NEAREST)
    plate_path = tmp_path / "background.png"
    cv2.imwrite(str(plate_path), plate)

    strokes_path = tmp_path / "strokes.json"
    strokes_path.write_text(json.dumps({"strokes": stroke()}))

    result = heal_file(
        plate_path,
        read_strokes(strokes_path),
        target_path=tmp_path / "healed.png",
        artifacts_dir=tmp_path / "artifacts",
        fade=FADE,
        radius=BRUSH,
        canvas=(SIZE, SIZE),
    )

    # The plate keeps its own resolution - the user's asset is not replaced
    # by a canvas-sized one - and the correction is where the user painted
    # it: the artefact's own pixels, twice as far into the plate.
    healed = cv2.imread(str(tmp_path / "healed.png"), cv2.IMREAD_UNCHANGED)
    assert healed.shape[:2] == (SIZE * 2, SIZE * 2)
    assert healed[64, 64, 2] < 40, "the artefact is still red after healing"
    assert healed[64, 64, 1] > 150, "the surrounding background was not painted over it"

    # And the rectangle the correction is cropped to is a rectangle in canvas
    # pixels, so the corpus never mixes a canvas size with plate pixels.
    bbox = result["bbox"]
    assert bbox["width"] <= SIZE
    assert bbox["height"] <= SIZE


def test_the_correction_is_written_out_as_material(tmp_path: Path) -> None:
    plate_path = tmp_path / "background.png"
    cv2.imwrite(str(plate_path), make_plate())

    strokes_path = tmp_path / "strokes.json"
    strokes_path.write_text(json.dumps({"strokes": stroke()}))

    target = tmp_path / "background.png"
    artifacts = tmp_path / "artifacts"

    result = heal_file(
        plate_path,
        read_strokes(strokes_path),
        target_path=target,
        artifacts_dir=artifacts,
        fade=FADE,
        radius=BRUSH,
    )

    content_path = Path(result["content"])
    mask_path = Path(result["mask"])
    replaced_path = Path(result["replaced"])

    assert content_path.name == CONTENT_FILENAME
    assert mask_path.name == MASK_FILENAME
    assert replaced_path.name == REPLACED_FILENAME
    assert content_path.exists() and mask_path.exists() and replaced_path.exists()

    # The artefacts are cropped to the painted rectangle, and all three share
    # it, so the content, the mask and the replaced pixels line up.
    bbox = result["bbox"]
    content = cv2.imread(str(content_path), cv2.IMREAD_UNCHANGED)
    mask = cv2.imread(str(mask_path), cv2.IMREAD_UNCHANGED)
    replaced = cv2.imread(str(replaced_path), cv2.IMREAD_UNCHANGED)

    assert content.shape[:2] == (bbox["height"], bbox["width"])
    assert mask.shape[:2] == (bbox["height"], bbox["width"])
    assert replaced.shape[:2] == (bbox["height"], bbox["width"])

    # The mask says what the brush covered ...
    assert mask.max() > 0
    assert mask[mask.shape[0] // 2, mask.shape[1] // 2] > 0

    # ... the replaced pixels are the artefact the user painted over ...
    assert replaced[replaced.shape[0] // 2, replaced.shape[1] // 2, 2] > 200

    # ... and the content is what replaced them: the surrounding background.
    assert content[content.shape[0] // 2, content.shape[1] // 2, 2] < 40

    # The plate on disk is the healed one.
    healed_on_disk = cv2.imread(str(target), cv2.IMREAD_UNCHANGED)
    assert healed_on_disk[32, 32, 2] < 40


def test_an_empty_stroke_is_refused() -> None:
    from core.errors import RigError

    with pytest.raises(RigError):
        heal_plate(make_plate(), [], fade=FADE, radius=BRUSH)


def _correction_entry(
    bbox: tuple[int, int, int, int],
    colour: tuple[int, int, int],
    canvas: tuple[int, int],
    band: int,
) -> dict:
    """One stored correction, in the shape the editor writes it."""
    x, y, width, height = bbox
    mask = np.full((height, width), 255, np.uint8)
    content = np.zeros((height, width, 4), np.uint8)
    content[:, :, :3] = colour
    content[:, :, 3] = 255

    return {
        "bbox": {"x": x, "y": y, "width": width, "height": height},
        "canvas": [canvas[0], canvas[1]],
        "fade": band,
        "mask": base64.b64encode(cv2.imencode(".png", mask)[1].tobytes()).decode(),
        "content": base64.b64encode(cv2.imencode(".png", content)[1].tobytes()).decode(),
    }


def test_corrections_are_applied_inside_their_own_rectangles(tmp_path: Path) -> None:
    """Each stored correction lands where it was painted, and only there."""
    canvas = (SIZE, SIZE)
    band = 2
    red = (0, 0, 255)
    green = (0, 255, 0)

    path = tmp_path / "corrections.json"
    path.write_text(
        json.dumps(
            {
                "corrections": [
                    _correction_entry((10, 10, 8, 8), red, canvas, band),
                    _correction_entry((40, 40, 8, 8), green, canvas, band),
                ]
            }
        )
    )

    corrections = load_corrections(path, (SIZE, SIZE))
    assert len(corrections) == 2

    colour = np.full((SIZE, SIZE, 3), 50, np.uint8)
    result = apply_corrections(colour, corrections)

    # The middle of each painted rectangle is that correction's own content.
    assert np.array_equal(result[14, 14], np.array(red, np.uint8))
    assert np.array_equal(result[44, 44], np.array(green, np.uint8))

    # The correction feathers out at its rectangle's edge: the border is the
    # untouched ground, not a hard edge.
    assert np.array_equal(result[10, 10], colour[10, 10])
    assert np.array_equal(result[40, 40], colour[40, 40])

    # Nothing outside the painted rectangles moved.
    outside = np.ones((SIZE, SIZE), bool)
    outside[10:18, 10:18] = False
    outside[40:48, 40:48] = False
    assert np.array_equal(result[outside], colour[outside])


def test_a_damaged_corrections_file_is_not_silently_ignored(tmp_path: Path) -> None:
    """The only source a rebuilt patch re-applies corrections from never fails open."""
    from core.errors import RigError

    path = tmp_path / "corrections.json"
    path.write_text("{not json")

    with pytest.raises(RigError):
        load_corrections(path, (SIZE, SIZE))

    path.write_text(
        json.dumps(
            {
                "corrections": [
                    {
                        "bbox": {"x": 0, "y": 0, "width": 4, "height": 4},
                        "canvas": [SIZE, SIZE],
                        "fade": 2,
                        "mask": "not base64",
                        "content": "not base64",
                    }
                ]
            }
        )
    )

    with pytest.raises(RigError):
        load_corrections(path, (SIZE, SIZE))

    missing = tmp_path / "missing.json"
    assert load_corrections(missing, (SIZE, SIZE)) == []


# --- the correction and the patch -------------------------------------------


def _rig() -> dict:
    """A rig whose character travels across the canvas."""
    return {
        "schema": "framer.rig",
        "version": 1,
        "id": "healing-scene",
        "name": "Healing scene",
        "canvas": {"width": SIZE, "height": SIZE},
        "source": {"kind": "image", "path": "source.png", "frame": 0},
        "duration": {"fps": 12, "frames": 6},
        "mesh": {"mode": "grid", "vertices": [], "triangles": [], "weights": []},
        "bones": [
            {
                "id": "b0",
                "name": "spine",
                "parent": None,
                "rest": {"head": [16, 48], "tail": [16, 32]},
                "radius": SIZE,
                "falloff": "smooth",
            }
        ],
        "bind": {"mode": "auto", "power": 2.0, "radius_scale": 1.0},
        "keyframes": [
            {"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}}},
            {"frame": 5, "pose": {"b0": {"rot": 0.0, "tx": 40, "ty": 0}}},
        ],
        "playback": {"loop": True},
        "layers": {
            "split": True,
            "character": "character.png",
            "tolerance": 40,
            "soft_edges": 0,
            "edge_cleanup": 0,
            "fade": 4,
        },
    }


def _scene() -> tuple[dict, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """The rig, its still, its character, and a plate the user replaced."""
    rig = _rig()

    source = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    source[:, :, 1] = 190
    source[:, :, 3] = 255
    source[32:48, 8:24] = (0, 0, 255, 255)

    alpha = character_alpha(source, tolerance=40, soft_edges=0, edge_cleanup=0)
    character, plate = split_layers(source, alpha)

    # A background the user replaced by hand, with a red mark in the strip
    # the character travels into: the automatic reconstruction smears a mark
    # like this one, which is exactly why the brush is there.
    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)
    region = character_region(rig, alpha, weights=weights)
    ys, xs = np.nonzero(region)
    centre_x = (int(xs.min()) + int(xs.max())) // 2
    centre_y = (int(ys.min()) + int(ys.max())) // 2
    plate[centre_y - 8 : centre_y + 8, centre_x - 8 : centre_x + 8] = (0, 0, 255, 255)

    return rig, source, character, plate, alpha


def _write_corrections(path: Path, result: dict, canvas: tuple[int, int] = (SIZE, SIZE)) -> None:
    """The project's corrections, in the shape the editor writes them."""
    bbox = result["bbox"]
    mask = cv2.imread(str(Path(result["mask"])), cv2.IMREAD_UNCHANGED)
    content = cv2.imread(str(Path(result["content"])), cv2.IMREAD_UNCHANGED)

    entry = {
        "bbox": bbox,
        "canvas": [canvas[0], canvas[1]],
        "fade": result["fade"],
        "mask": base64.b64encode(cv2.imencode(".png", mask)[1].tobytes()).decode(),
        "content": base64.b64encode(cv2.imencode(".png", content)[1].tobytes()).decode(),
    }
    path.write_text(json.dumps({"corrections": [entry]}))


def test_the_patch_shows_the_correction_and_keeps_it(tmp_path: Path) -> None:
    """
    The correction is what the frame shows - before and after a rebuild.

    The patch is the ground the character uncovers, reconstructed from the
    plate.  A correction the user painted into that ground is the very case
    the brush exists for, so the patch has to show it - and a patch that is
    rebuilt (the feather changed, the motion changed) has to show it again.
    """
    rig, source, character, plate, alpha = _scene()
    source_path = tmp_path / "source.png"
    cv2.imwrite(str(source_path), source)
    write_layer(tmp_path / "character.png", character)
    write_layer(tmp_path / "background.png", plate)

    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)
    region = character_region(rig, alpha, weights=weights)
    ys, xs = np.nonzero(region)
    assert xs.size > 0, "the scene has no swept area to correct"

    # The user paints over the ground the patch invents, in the middle of the
    # swept area, and heals it.
    centre_x = (int(xs.min()) + int(xs.max())) // 2
    centre_y = (int(ys.min()) + int(ys.max())) // 2
    strokes = [{"points": [[centre_x, centre_y]], "radius": 6}]

    healed = heal_file(
        tmp_path / "background.png",
        strokes,
        target_path=tmp_path / "background.png",
        artifacts_dir=tmp_path / "artifacts",
        fade=FADE,
        radius=6,
        canvas=(SIZE, SIZE),
    )
    _write_corrections(corrections_path(source_path), healed)

    healed_plate = cv2.imread(str(tmp_path / "background.png"), cv2.IMREAD_UNCHANGED)

    def frame_for(rig_document: dict) -> np.ndarray:
        """One frame through the engine's own render, as the editor runs it."""
        rig_path = tmp_path / f"rig_{rig_document['layers']['fade']}.json"
        rig_path.write_text(json.dumps(rig_document))
        output = tmp_path / f"frame_{rig_document['layers']['fade']}.png"

        result = deform_video(
            input_path=str(source_path),
            output_path=str(output),
            rig=str(rig_path),
            start_frame=0,
            end_frame=0,
            fps=12.0,
            iterations=6,
            still=True,
        )
        assert result["success"], result.get("error")

        image = cv2.imread(str(output), cv2.IMREAD_UNCHANGED)
        assert image is not None
        return image

    def ground_frame(rig_document: dict) -> np.ndarray:
        """The same frame without the correction: the ground the engine invented."""
        corrections = corrections_path(source_path)
        saved = corrections.read_bytes()
        corrections.unlink()

        try:
            return frame_for(rig_document)
        finally:
            corrections.write_bytes(saved)

    def assert_shows_the_correction(frame: np.ndarray, ground_frame: np.ndarray) -> None:
        """The painted area carries the correction, not the invented ground."""
        mask = stroke_mask((SIZE, SIZE), strokes, 6)
        ys, xs = np.nonzero(mask > 0)
        assert len(ys) > 0

        moved = np.abs(frame[ys, xs, :3].astype(int) - ground_frame[ys, xs, :3].astype(int))
        assert moved.mean() > 10, "the patch painted over the correction"

        # And the frame moved towards the correction, not away from it.
        to_correction = np.abs(frame[ys, xs, :3].astype(int) - healed_plate[ys, xs, :3].astype(int))
        to_ground = np.abs(
            ground_frame[ys, xs, :3].astype(int) - healed_plate[ys, xs, :3].astype(int)
        )
        assert to_correction.mean() < to_ground.mean()

    # The frame the user sees shows the correction ...
    frame = frame_for(rig)
    assert_shows_the_correction(frame, ground_frame(rig))

    # ... and it still shows it after the patch is rebuilt: the feather
    # changed, so the patch is built again - with the correction in it.
    rebuilt = dict(rig)
    rebuilt["layers"] = dict(rig["layers"], fade=8)
    frame_after = frame_for(rebuilt)
    assert_shows_the_correction(frame_after, ground_frame(rebuilt))


def test_the_patch_is_rebuilt_when_a_correction_is_added(tmp_path: Path) -> None:
    """A correction is part of the patch's identity, so the patch is stale."""
    rig, source, character, plate, _alpha = _scene()
    source_path = tmp_path / "source.png"
    cv2.imwrite(str(source_path), source)
    write_layer(tmp_path / "background.png", plate)

    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)

    _patch, path = resolve_patch_layer(rig, source_path, character, plate, weights=weights)
    assert path is not None and path.exists()

    # The same rig, with a correction painted into the ground: the patch is
    # stale now, because the ground it shows is not the ground any more.
    strokes = [{"points": [[32, 40]], "radius": 6}]
    healed = heal_file(
        tmp_path / "background.png",
        strokes,
        target_path=tmp_path / "background.png",
        artifacts_dir=tmp_path / "artifacts",
        fade=FADE,
        radius=6,
        canvas=(SIZE, SIZE),
    )
    _write_corrections(corrections_path(source_path), healed)

    stale, path = resolve_patch_layer(
        rig, source_path, character, plate, weights=weights, build=False
    )
    assert stale is None, "the patch was not stale after a correction"


def test_a_correction_from_another_canvas_is_not_reapplied(tmp_path: Path) -> None:
    """
    A correction painted on another canvas does not belong here.

    The source was replaced and the canvas changed with it, so the
    correction's rectangle no longer says where the correction belongs: it
    must not be painted over the new canvas at the old offset.
    """
    rig, source, character, plate, alpha = _scene()
    source_path = tmp_path / "source.png"
    cv2.imwrite(str(source_path), source)
    write_layer(tmp_path / "background.png", plate)

    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)

    strokes = [{"points" : [[32, 40]], "radius": 6}]
    healed = heal_file(
        tmp_path / "background.png",
        strokes,
        target_path=tmp_path / "background.png",
        artifacts_dir=tmp_path / "artifacts",
        fade=FADE,
        radius=6,
        canvas=(SIZE, SIZE),
    )
    # The correction was painted on a canvas of another size.
    _write_corrections(corrections_path(source_path), healed, canvas=(SIZE // 2, SIZE // 2))

    patch, _path = resolve_patch_layer(
        rig, source_path, character, plate, weights=weights, iterations=6
    )
    ground = build_patch(rig, alpha, plate, fade=FADE, weights=weights, iterations=6)
    assert np.array_equal(patch[:, :, :3], ground[:, :, :3]), "a stale correction was applied"


def test_a_correction_reaching_past_the_canvas_is_clipped(tmp_path: Path) -> None:
    """A correction at the canvas's edge is placed where it still belongs."""
    rig, source, character, plate, alpha = _scene()
    source_path = tmp_path / "source.png"
    cv2.imwrite(str(source_path), source)
    write_layer(tmp_path / "background.png", plate)

    weights = load_or_build_weights(rig, width=SIZE, height=SIZE)

    strokes = [{"points": [[56, 56]], "radius": 6}]
    healed = heal_file(
        tmp_path / "background.png",
        strokes,
        target_path=tmp_path / "background.png",
        artifacts_dir=tmp_path / "artifacts",
        fade=FADE,
        radius=6,
        canvas=(SIZE, SIZE),
    )

    # The correction's rectangle reaches past the canvas's edge.
    path = corrections_path(source_path)
    _write_corrections(path, healed)
    payload = json.loads(path.read_text())
    payload["corrections"][0]["bbox"]["x"] = SIZE - 4
    path.write_text(json.dumps(payload))

    patch, _path = resolve_patch_layer(
        rig, source_path, character, plate, weights=weights, iterations=6
    )
    ground = build_patch(rig, alpha, plate, fade=FADE, weights=weights, iterations=6)

    # The part of the correction that fits the canvas is applied, and the
    # build does not fall over the part that does not.
    assert not np.array_equal(patch[:, :, :3], ground[:, :, :3])


def test_the_healed_plate_is_written_in_the_format_its_name_implies(tmp_path: Path) -> None:
    """A layer the editor calls a .jpg has to hold JPEG bytes.

    The editor serves a layer with the content type its name promises, so a
    plate the project calls ``background_replaced.jpg`` may not hold PNG
    bytes under that name.
    """
    plate_path = tmp_path / "background_replaced.jpg"
    cv2.imwrite(str(plate_path), make_plate())

    strokes_path = tmp_path / "strokes.json"
    strokes_path.write_text(json.dumps({"strokes": stroke()}))

    heal_file(
        plate_path,
        read_strokes(strokes_path),
        target_path=plate_path,
        artifacts_dir=tmp_path / "artifacts",
        fade=FADE,
        radius=BRUSH,
    )

    assert plate_path.read_bytes()[:3] == b"\xff\xd8\xff", "the healed plate is not a JPEG"

    # And it is still a readable plate.
    healed = cv2.imread(str(plate_path), cv2.IMREAD_UNCHANGED)
    assert healed is not None
    assert healed.shape[:2] == (SIZE, SIZE)
