#!/usr/bin/env python3
"""
Framer Python Port worker.

This is the operation layer of the Elixir/OTP orchestrator.  The BEAM never
sees pixel data: it only sends *file paths*, a *frame range* and *options* to
this process, which reads the input, processes the chunk and writes the output
chunk file.

One worker process is meant to be long lived (one per Elixir ``PortWorker`` /
``Player``); it serves requests sequentially so a worker never runs more than
one chunk at a time.

Wire protocol
-------------
Length prefixed JSON over stdin/stdout, 4 byte big-endian unsigned length
followed by the UTF-8 JSON payload.

Request::

    {
      "id":          "uuid",            # opaque correlation id, echoed back
      "op":          "remove-bg",       # remove-bg | fps-boost | loop | deform | merge | info
      "input":       "/abs/input",      # source file (or nil for merge)
      "output":      "/abs/output",     # destination chunk file
      "start_frame": 0,                 # inclusive
      "end_frame":   49,                # inclusive
      "fps":         30.0,              # source fps (optional for some ops)
      "options":     { ... }            # operation specific options (JSON object)
    }

Response::

    {"id": "uuid", "status": "ok",    "output": "/abs/output", "frames": 50, ...}
    {"id": "uuid", "status": "error", "error": "human readable reason"}

Any stdout produced by the imported OpenCV/FFmpeg core is redirected to stderr
at start-up so it can never corrupt the protocol stream.
"""

from __future__ import annotations

import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any

# Make the repository root importable regardless of the working directory the
# Elixir port was spawned from.
REPO_ROOT = Path(__file__).resolve().parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _ffmpeg() -> str:
    return shutil.which("ffmpeg") or "ffmpeg"


def _ffprobe() -> str:
    return shutil.which("ffprobe") or "ffprobe"


def _as_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)


def _probe_video(input_path: str) -> dict[str, Any]:
    """Return width/height/fps/total_frames for a video using ffprobe."""
    cmd = [
        _ffprobe(), "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames",
        "-show_entries", "format=duration",
        "-of", "json", input_path,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    data = json.loads(out)
    stream = (data.get("streams") or [{}])[0]

    def parse_rate(value: str | None) -> float:
        if not value or value == "0/0":
            return 0.0
        num, _, den = value.partition("/")
        try:
            return float(num) / float(den) if den else float(num)
        except (TypeError, ValueError, ZeroDivisionError):
            return 0.0

    fps = parse_rate(stream.get("avg_frame_rate")) or parse_rate(stream.get("r_frame_rate"))
    width = int(stream.get("width") or 0)
    height = int(stream.get("height") or 0)
    total = int(stream.get("nb_frames") or 0)

    if total <= 0:
        duration = 0.0
        try:
            duration = float(data.get("format", {}).get("duration") or 0.0)
        except (TypeError, ValueError):
            duration = 0.0
        if duration and fps:
            total = round(duration * fps)

    if total <= 0:
        # Last resort: count decoded frames.
        try:
            count_cmd = [
                _ffprobe(), "-v", "error", "-select_streams", "v:0",
                "-count_frames", "-show_entries", "stream=nb_read_frames",
                "-of", "csv=p=0", input_path,
            ]
            counted = subprocess.run(count_cmd, capture_output=True, text=True, check=False).stdout.strip()
            total = int(counted)
        except (ValueError, subprocess.SubprocessError):
            total = 0

    return {"width": width, "height": height, "fps": fps, "total_frames": total}


def _chunk_bounds(req: dict[str, Any], total_frames: int) -> tuple[int, int]:
    start = int(req.get("start_frame") or 0)
    end = req.get("end_frame")
    if end is None or int(end) < 0:
        end = total_frames - 1
    end = min(int(end), total_frames - 1)
    start = max(0, min(start, max(end, 0)))
    return start, end


def _alpha_codec_args(output_path: str, has_alpha: bool) -> list[str]:
    """Pick encoder arguments based on the output extension."""
    ext = Path(output_path).suffix.lower()
    if ext == ".webm":
        args = ["-c:v", "libvpx-vp9", "-auto-alt-ref", "0", "-crf", "30", "-b:v", "0"]
        args += ["-pix_fmt", "yuva420p" if has_alpha else "yuv420p"]
        return args
    if ext == ".mov":
        if has_alpha:
            return ["-c:v", "qtrle", "-pix_fmt", "yuva420p"]
        return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23"]
    if ext == ".gif":
        return ["-loop", "0"]
    # mp4 / default
    return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "23"]


# ---------------------------------------------------------------------------
# operations
# ---------------------------------------------------------------------------

def op_info(req: dict[str, Any]) -> dict[str, Any]:
    info = _probe_video(req["input"])
    return {"output": req.get("output"), **info}


def op_remove_bg(req: dict[str, Any]) -> dict[str, Any]:
    """Key the background out of a frame range and write a BGRA chunk."""
    import cv2

    from core.bg_removal import _remove_bg_frame_processor
    from core.color_ranges import (
        detect_background_color_from_video,
        generate_color_ranges,
    )
    from core.motion_detection import detect_motion_region
    from core.utils import parse_color
    from core.video import VideoStreamWriter

    input_path = req["input"]
    output_path = req["output"]
    opts = req.get("options") or {}

    info = _probe_video(input_path)
    total_frames = info["total_frames"]
    width, height = info["width"], info["height"]
    fps = float(req.get("fps") or info["fps"] or 30.0)
    start, end = _chunk_bounds(req, total_frames)

    tolerance = int(opts.get("tolerance", 30))
    background_color = parse_color(opts.get("color")) if opts.get("color") else None
    if background_color is None:
        detected = detect_background_color_from_video(input_path, tolerance=tolerance)
        background_color = detected[0] if detected else [115, 188, 129]

    if _as_bool(opts.get("auto_ranges"), True):
        color_ranges = generate_color_ranges(
            background_color, int(opts.get("num_ranges", 5)), tolerance
        )
    else:
        color_ranges = [{"color": background_color, "tolerance": tolerance}]

    method = (opts.get("method") or "color").lower()
    motion_mask = None
    if method in ("motion", "combined"):
        motion_mask = detect_motion_region(
            input_path,
            num_frames=int(opts.get("motion_frames", 30)),
            threshold=int(opts.get("motion_threshold", 15)),
            dilate_kernel=11,
        )

    frame_kwargs = {
        "color_ranges": color_ranges,
        "method": method,
        "motion_mask": motion_mask,
        "background_color": background_color,
        "tolerance": tolerance,
        "refine": _as_bool(opts.get("refine"), False),
        "refine_tolerance": int(opts.get("refine_tolerance", 45)),
        "refine_block_size": int(opts.get("refine_block_size", 32)),
        "edge_cleanup": int(opts.get("edge_cleanup", 3)),
        "soft_edges": int(opts.get("edges", 5)),
        "adaptive_bg": _as_bool(opts.get("adaptive_bg"), False),
        "use_gpu": not _as_bool(opts.get("force_cpu"), False),
    }

    cap = cv2.VideoCapture(input_path)
    if not cap.isOpened():
        raise RuntimeError(f"Could not open input video: {input_path}")
    cap.set(cv2.CAP_PROP_POS_FRAMES, start)

    frames = 0
    with VideoStreamWriter(output_path, fps, width, height, has_alpha=True) as writer:
        for _ in range(start, end + 1):
            ok, frame = cap.read()
            if not ok:
                break
            writer.write_frame(_remove_bg_frame_processor(frame, **frame_kwargs))
            frames += 1
    cap.release()

    if frames == 0:
        raise RuntimeError(f"No frames processed for range {start}-{end} of {input_path}")

    return {
        "output": output_path,
        "frames": frames,
        "background_color": list(background_color),
        "method": method,
    }


def op_fps_boost(req: dict[str, Any]) -> dict[str, Any]:
    """Interpolate a frame range to a higher frame rate (FFmpeg)."""
    input_path = req["input"]
    output_path = req["output"]
    opts = req.get("options") or {}

    info = _probe_video(input_path)
    total_frames = info["total_frames"]
    fps = float(req.get("fps") or info["fps"] or 30.0)
    start, end = _chunk_bounds(req, total_frames)

    target_fps = int(opts.get("target_fps") or req.get("target_fps") or 60)
    start_time = start / fps if fps else 0.0
    duration = (end - start + 1) / fps if fps else None

    from core.video import has_alpha_channel

    has_alpha = has_alpha_channel(input_path)
    ext = Path(output_path).suffix.lower()
    if has_alpha and ext == ".mp4":
        raise RuntimeError("MP4 does not support alpha; use .webm or .mov")

    cmd = [_ffmpeg(), "-y", "-ss", f"{start_time:.6f}", "-i", input_path]
    if duration and duration > 0:
        cmd += ["-t", f"{duration:.6f}"]

    # minterpolate gives real interpolation; ``fps`` filter is the honest
    # fallback when the build lacks it.  No frame overlap is encoded, so the
    # concatenated chunks never duplicate boundary frames.
    filters = []
    try:
        filters_out = subprocess.run(
            [_ffmpeg(), "-filters"], capture_output=True, text=True, check=False
        ).stdout
        has_minterpolate = "minterpolate" in filters_out
    except subprocess.SubprocessError:
        has_minterpolate = False

    if fps and target_fps > fps and has_minterpolate:
        filters.append(
            f"minterpolate=fps={target_fps}:mi_mode=mci:mc_mode=aobmc:"
            f"me_mode=bidir:vsbmc=1"
        )
    else:
        filters.append(f"fps={target_fps}")
    if has_alpha:
        filters.append("format=yuva420p")
    cmd += ["-vf", ",".join(filters)]
    cmd += _alpha_codec_args(output_path, has_alpha)
    cmd.append(output_path)

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"FFmpeg fps-boost failed: {proc.stderr[-2000:]}")

    return {"output": output_path, "target_fps": target_fps, "frames": (end - start + 1)}


def op_loop(req: dict[str, Any]) -> dict[str, Any]:
    """Create a seamless loop for a whole file (single Port call)."""
    from ops.loop import create_loop

    opts = dict(req.get("options") or {})
    opts.pop("config", None)
    # Only pass parameters the operation understands.
    allowed = {
        "method", "fade_color", "fade_frames", "fade_type", "morph_steps",
        "cycle_frames", "hold_frames", "blend_mode", "ramp_factor",
        "analyze_only", "progress", "until", "workers",
    }
    kwargs = {k: v for k, v in opts.items() if k in allowed and v is not None}
    kwargs.setdefault("progress", False)
    result = create_loop(input_path=req["input"], output_path=req["output"], **kwargs)
    if not result.get("success"):
        raise RuntimeError(result.get("error") or "loop operation failed")
    return {"output": req["output"]}


def op_deform(req: dict[str, Any]) -> dict[str, Any]:
    """Puppet-warp a still image over a chunk range with a rig/bones document.

    The source is a still image (read once, looped over ``[start_frame,
    end_frame]``) or a video (its first frame is used); either way the chunk
    writes an alpha-capable frame range and the BEAM only ever sends paths,
    the range and the rig/options - never pixel data.
    """
    from ops.deform import deform_video

    opts = req.get("options") or {}

    rig = opts.get("rig") or opts.get("rig_path")
    if not rig:
        raise RuntimeError("deform requires a 'rig' option pointing at a framer.rig document")

    result = deform_video(
        input_path=req["input"],
        output_path=req["output"],
        rig=rig,
        start_frame=req.get("start_frame"),
        end_frame=req.get("end_frame"),
        fps=req.get("fps"),
        iterations=int(opts.get("iterations", 5)),
        weights=opts.get("weights"),
        still=opts.get("still"),
        radius_scale=opts.get("radius_scale"),
    )

    if not result.get("success"):
        raise RuntimeError(result.get("error") or "deform operation failed")

    return {"output": result["output_path"], "frames": result.get("frames", 0)}


def op_merge(req: dict[str, Any]) -> dict[str, Any]:
    """Concatenate finished chunk files into the final output."""
    opts = req.get("options") or {}
    chunks: list[str] = [str(c) for c in (opts.get("chunks") or [])]
    output_path = req["output"]

    if not chunks:
        raise RuntimeError("merge requires a non-empty 'chunks' option")

    if len(chunks) == 1:
        shutil.copyfile(chunks[0], output_path)
        return {"output": output_path, "chunks": 1}

    concat_path = None
    try:
        fd, concat_path = tempfile.mkstemp(suffix=".txt", prefix="framer_concat_")
        with os.fdopen(fd, "w") as handle:
            for chunk in chunks:
                handle.write(f"file '{os.path.abspath(chunk)}'\n")

        cmd = [
            _ffmpeg(), "-y", "-f", "concat", "-safe", "0",
            "-i", concat_path, "-c", "copy", output_path,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"FFmpeg merge failed: {proc.stderr[-2000:]}")
    finally:
        if concat_path and os.path.exists(concat_path):
            os.unlink(concat_path)

    return {"output": output_path, "chunks": len(chunks)}


_OPERATIONS = {
    "info": op_info,
    "remove-bg": op_remove_bg,
    "fps-boost": op_fps_boost,
    "loop": op_loop,
    "deform": op_deform,
    "merge": op_merge,
}


def handle_request(req: dict[str, Any]) -> dict[str, Any]:
    req_id = req.get("id")
    try:
        op = req.get("op")
        handler = _OPERATIONS.get(op)
        if handler is None:
            raise ValueError(f"Unknown operation: {op!r}")
        payload = handler(req) or {}
        payload.pop("id", None)
        return {"id": req_id, "status": "ok", **payload}
    except Exception as exc:  # noqa: BLE001 - report any failure to the BEAM
        traceback.print_exc(file=sys.stderr)
        return {"id": req_id, "status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------

def main() -> int:
    # Reserve the original stdout for the protocol and point everything else
    # (including C-level writes from OpenCV/FFmpeg) at stderr.
    protocol = os.fdopen(os.dup(1), "wb", buffering=0)
    os.dup2(2, 1)
    stdin = sys.stdin.buffer

    while True:
        header = stdin.read(4)
        if not header or len(header) < 4:
            break
        (length,) = struct.unpack(">I", header)
        body = b""
        while len(body) < length:
            part = stdin.read(length - len(body))
            if not part:
                break
            body += part

        try:
            request = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            response = {"id": None, "status": "error", "error": f"bad JSON: {exc}"}
        else:
            response = handle_request(request)

        encoded = json.dumps(response).encode("utf-8")
        protocol.write(struct.pack(">I", len(encoded)) + encoded)
        protocol.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
