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
2. **The falloff is the patch's falloff.** The correction is composited with
   `core.patch.feather_ramp`, the very ramp the automatic patch feathers with,
   so the two are the same kind of fix.
3. **There is no hard edge.** The transition from the untouched background
   into the correction is gradual, and the background outside the painted area
   is byte-for-byte untouched.
4. **The plate stays opaque.** The feather lives on the correction, never as a
   hole in the plate.
5. **The correction is material.** The content that was painted, the mask it
   covered and the pixels it replaced are written out, cropped to the painted
   rectangle - the training material, stored from the first use.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core.healing import (
    CONTENT_FILENAME,
    MASK_FILENAME,
    REPLACED_FILENAME,
    heal_file,
    heal_plate,
    read_strokes,
)
from core.patch import feather_ramp, reconstruct

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


def test_the_correction_uses_the_patch_falloff() -> None:
    plate = make_plate()
    strokes = stroke()
    result = heal_plate(plate, strokes, fade=FADE, radius=BRUSH)

    mask = result["mask"]
    ramp = feather_ramp(mask, FADE)
    content = reconstruct(plate, mask)

    expected = plate[:, :, :3].astype(np.float32) * (1 - ramp[:, :, None] / 255.0) + content.astype(
        np.float32
    ) * (ramp[:, :, None] / 255.0)

    assert np.allclose(result["plate"][:, :, :3], np.clip(expected, 0, 255), atol=1.0)


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
    core = cv2.erode(mask, kernel, iterations=FADE + 2)
    ys, xs = np.nonzero(core)
    assert len(ys) > 0
    assert np.array_equal(healed[ys, xs, :3], content[ys, xs, :3])


def test_the_plate_stays_opaque() -> None:
    plate = make_plate()
    result = heal_plate(plate, stroke(), fade=FADE, radius=BRUSH)

    assert (result["plate"][:, :, 3] == 255).all()


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
