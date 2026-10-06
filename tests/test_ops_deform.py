"""
Operation-level tests for `deform` (`ops/deform.py` and the Port worker).

These exercise the real files: a PNG still is read once, looped over a frame
range, and written as an alpha-capable video (or a single PNG when the output
extension is an image).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

import framer_worker  # noqa: E402
from ops.deform import deform_video  # noqa: E402


def make_rig(tmp_path: Path, frames: int = 8, fps: float = 8.0) -> Path:
    rig = {
        "schema": "framer.rig",
        "version": 1,
        "canvas": {"width": 32, "height": 32},
        "bones": [
            {
                "id": "b0",
                "name": "root",
                "parent": None,
                "rest": {"head": [16, 16], "tail": [16, 4]},
                "radius": 200,
            }
        ],
        "bind": {"power": 2.0, "radius_scale": 1.0},
        "keyframes": [
            {"frame": 0, "pose": {"b0": {"rot": 0.0, "tx": 0, "ty": 0}}},
            {"frame": frames - 1, "pose": {"b0": {"rot": 0.0, "tx": 8, "ty": 0}}},
        ],
        "duration": {"fps": fps, "frames": frames},
    }
    path = tmp_path / "rig.json"
    path.write_text(json.dumps(rig))
    return path


def test_deform_is_registered_in_the_port_operations():
    assert "deform" in framer_worker._OPERATIONS
    assert callable(framer_worker._OPERATIONS["deform"])


def test_deform_video_writes_an_alpha_video_for_the_requested_range(tmp_path, tiny_still):
    rig_path = make_rig(tmp_path)
    output = tmp_path / "chunk.webm"

    result = deform_video(
        input_path=str(tiny_still),
        output_path=str(output),
        rig=str(rig_path),
        start_frame=0,
        end_frame=3,
        fps=4.0,
    )

    assert result["success"] is True, result.get("error")
    assert result["frames"] == 4
    assert output.exists()

    # Decode with libvpx-vp9: FFmpeg's native VP9 decoder drops the alpha plane.
    import subprocess

    raw = subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-c:v",
            "libvpx-vp9",
            "-i",
            str(output),
            "-frames:v",
            "1",
            "-pix_fmt",
            "bgra",
            "-f",
            "rawvideo",
            "-",
        ],
        capture_output=True,
    ).stdout
    assert len(raw) >= 32 * 32 * 4
    frame = np.frombuffer(raw[: 32 * 32 * 4], dtype=np.uint8).reshape(32, 32, 4)
    assert frame.shape[2] == 4


def test_deform_video_writes_a_single_frame_png(tmp_path, tiny_still):
    rig_path = make_rig(tmp_path)
    output = tmp_path / "frame.png"

    result = deform_video(
        input_path=str(tiny_still),
        output_path=str(output),
        rig=str(rig_path),
        start_frame=0,
        end_frame=0,
    )

    assert result["success"] is True, result.get("error")
    assert result["frames"] == 1
    written = cv2.imread(str(output), cv2.IMREAD_UNCHANGED)
    assert written is not None
    assert written.shape == (32, 32, 4)


def test_deform_video_defaults_the_range_to_the_rig_duration(tmp_path, tiny_still):
    rig_path = make_rig(tmp_path, frames=5)
    output = tmp_path / "default.webm"

    result = deform_video(
        input_path=str(tiny_still),
        output_path=str(output),
        rig=str(rig_path),
    )

    assert result["success"] is True, result.get("error")
    assert result["frames"] == 5
    assert result["end_frame"] == 4


def test_deform_video_errors_without_a_rig(tmp_path, tiny_still):
    result = deform_video(
        input_path=str(tiny_still),
        output_path=str(tmp_path / "out.webm"),
        rig=None,
    )
    assert result["success"] is False
    assert "rig" in result["error"].lower()


def test_deform_video_rejects_mp4_when_the_still_has_alpha(tmp_path, tiny_still):
    rig_path = make_rig(tmp_path)
    result = deform_video(
        input_path=str(tiny_still),
        output_path=str(tmp_path / "out.mp4"),
        rig=str(rig_path),
    )
    assert result["success"] is False
    assert "alpha" in result["error"].lower()


def test_deform_video_reports_a_bad_rig_version(tmp_path, tiny_still):
    path = tmp_path / "bad_rig.json"
    path.write_text(json.dumps({"schema": "framer.rig", "version": 2}))
    result = deform_video(
        input_path=str(tiny_still),
        output_path=str(tmp_path / "out.webm"),
        rig=str(path),
    )
    assert result["success"] is False
    assert "version" in result["error"]


def test_op_deform_handles_a_port_request(tmp_path, tiny_still):
    rig_path = make_rig(tmp_path)
    output = tmp_path / "port_chunk.webm"

    response = framer_worker.op_deform(
        {
            "op": "deform",
            "input": str(tiny_still),
            "output": str(output),
            "start_frame": 2,
            "end_frame": 5,
            "fps": 8.0,
            "options": {"rig": str(rig_path), "iterations": 4},
        }
    )

    assert response["output"] == str(output)
    assert response["frames"] == 4
    assert output.exists()


def test_op_deform_raises_when_the_request_has_no_rig(tmp_path, tiny_still):
    import pytest

    with pytest.raises(RuntimeError, match="rig"):
        framer_worker.op_deform(
            {
                "op": "deform",
                "input": str(tiny_still),
                "output": str(tmp_path / "x.webm"),
                "start_frame": 0,
                "end_frame": 0,
                "options": {},
            }
        )
