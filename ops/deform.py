"""
Deform operation: rig/bones puppet-warp of a still image over a frame range.

This is the file-facing half of the deform engine.  The math lives in
``core/deform.py``; this module turns a request (paths + frame range + JSON
options) into a rendered chunk.  It is shared by the Python CLI and by the
Port worker, so the CLI and the orchestrator run the exact same code.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2

from core import register_operation
from core.deform import (
    IMAGE_EXTENSIONS,
    DeformRenderer,
    RigError,
    load_rig,
    load_source,
)
from core.layers import is_split, resolve_character_layer
from core.video import VideoStreamWriter


def _resolve_rig(rig: Any) -> dict[str, Any]:
    if isinstance(rig, dict):
        from core.deform import validate_rig

        return validate_rig(rig)
    if isinstance(rig, (str, Path)):
        return load_rig(rig)
    raise RigError("a rig is required: pass 'rig' as a path or a rig document")


def _resolve_frame_range(
    rig: dict[str, Any],
    start_frame: int | None,
    end_frame: int | None,
) -> tuple[int, int]:
    start = int(start_frame or 0)

    if end_frame is not None and int(end_frame) >= 0:
        end = int(end_frame)
    else:
        duration = rig.get("duration") or {}
        frames = duration.get("frames")
        if not frames:
            raise RigError(
                "end_frame was not supplied and the rig has no duration.frames to loop a still over"
            )
        end = int(frames) - 1

    if end < start:
        raise RigError(f"invalid frame range {start}-{end}")
    return start, end


def deform_video(
    input_path: str,
    output_path: str,
    rig: Any,
    start_frame: int | None = None,
    end_frame: int | None = None,
    fps: float | None = None,
    iterations: int = 5,
    weights: str | None = None,
    still: bool | None = None,
    radius_scale: float | None = None,
    progress: bool = False,
    **_: Any,
) -> dict[str, Any]:
    """
    Deform ``input_path`` over ``[start_frame, end_frame]`` and write ``output_path``.

    ``input_path`` may be a still image (read once and looped over the range,
    the convention the design settles on) or a video (its first frame is used as
    the source).  ``fps`` defaults to ``rig.duration.fps``; the frame count comes
    from ``rig.duration.frames`` when ``end_frame`` is omitted.

    When ``output_path`` is an image extension a single PNG (the ``start_frame``
    pose) is written instead of a video, which is the editor's "render one frame"
    path and the golden-image test path.

    A rig document that declares ``layers.split`` renders split: the character
    layer is deformed and the untouched background plate is composited under it,
    so the background is identical in every frame.
    """
    try:
        rig_document = _resolve_rig(rig)

        if radius_scale is not None:
            rig_document = {
                **rig_document,
                "bind": {**(rig_document.get("bind") or {}), "radius_scale": float(radius_scale)},
            }

        start, end = _resolve_frame_range(rig_document, start_frame, end_frame)

        duration = rig_document.get("duration") or {}
        resolved_fps = float(fps or duration.get("fps") or 24.0)

        source = load_source(input_path, still=still)
        width = int(rig_document["canvas"]["width"])
        height = int(rig_document["canvas"]["height"])

        character_layer = None
        materialised = None
        if is_split(rig_document):
            character_layer, materialised = resolve_character_layer(
                rig_document, source, input_path
            )

        renderer = DeformRenderer(
            rig_document,
            source,
            iterations=iterations,
            weights_cache=weights,
            still=still,
            character=character_layer,
        )

        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)

        if output.suffix.lower() in IMAGE_EXTENSIONS:
            renderer.render_to_png(start, output)
            result = {
                "success": True,
                "output_path": str(output),
                "frames": 1,
                "start_frame": start,
                "end_frame": start,
                "fps": resolved_fps,
            }
            if materialised is not None:
                result["character"] = str(materialised)
            return result

        # MP4 drops alpha on encode, so the *rendered* frame is what decides
        # whether the format can carry the output: a split rig composites over
        # an opaque plate and never needs alpha, but a deformation that pulls
        # transparency in from outside the canvas still cannot be encoded.
        frames = 0
        is_mp4 = output.suffix.lower() == ".mp4"
        alpha_error = False
        with VideoStreamWriter(output_path, resolved_fps, width, height, has_alpha=True) as writer:
            for frame in range(start, end + 1):
                rendered = renderer.render(frame)
                if is_mp4 and _has_transparency(rendered):
                    alpha_error = True
                    break
                writer.write_frame(rendered)
                frames += 1

        if alpha_error:
            output.unlink(missing_ok=True)
            return {
                "success": False,
                "output_path": None,
                "error": "MP4 does not support alpha; use .webm or .mov for a transparent rig",
            }

        if frames == 0:
            return {
                "success": False,
                "output_path": None,
                "error": f"no frames rendered for range {start}-{end}",
            }

        return {
            "success": True,
            "output_path": str(output),
            "frames": frames,
            "start_frame": start,
            "end_frame": end,
            "fps": resolved_fps,
            **({"character": str(materialised)} if materialised is not None else {}),
        }

    except (RigError, cv2.error, OSError, ValueError) as exc:
        return {"success": False, "output_path": None, "error": str(exc)}


def _has_transparency(source) -> bool:
    if source.ndim != 3 or source.shape[2] != 4:
        return False
    return bool((source[:, :, 3] < 255).any())


register_operation(
    name="deform",
    func=deform_video,
    args_schema={
        "rig": {
            "type": "string",
            "short": "-r",
            "description": "Path to the framer.rig JSON document",
        },
        "start_frame": {
            "type": "int",
            "default": 0,
            "description": "First frame of the range (inclusive)",
        },
        "end_frame": {
            "type": "int",
            "default": None,
            "description": "Last frame of the range (inclusive); defaults to rig.duration.frames",
        },
        "iterations": {
            "type": "int",
            "default": 5,
            "description": "Fixed-point iterations used to invert the skinning map",
        },
        "weights": {
            "type": "string",
            "default": None,
            "description": "Optional path to a cached dense-weight .npz file",
        },
        "radius_scale": {
            "type": "float",
            "default": None,
            "description": "Scale every bone influence radius (overrides rig.bind.radius_scale)",
        },
    },
    description="Deform a still image with a rig/bones puppet warp",
)
