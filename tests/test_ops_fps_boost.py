"""
Basic tests for the `fps-boost` operation (`ops/fps_boost.py`).

Covers the pure error path, the FFmpeg command shape (mocked) and a real
FFmpeg run that actually raises the frame rate.  FFmpeg is a hard project
dependency, so the real test fails loudly rather than skipping when it is
missing.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from core import get_registry
from ops.fps_boost import boost_fps


def test_fps_boost_is_registered():
    assert "fps-boost" in get_registry().list_operations()


def test_boost_fps_missing_input_reports_an_error(tmp_path):
    result = boost_fps(str(tmp_path / "missing.mp4"), str(tmp_path / "out.mp4"), to=60)
    assert result["success"] is False
    assert "not found" in result["error"]


def test_boost_fps_builds_an_interpolation_command(tmp_path):
    input_path = tmp_path / "in.mp4"
    input_path.write_bytes(b"fake")
    output_path = str(tmp_path / "out.mp4")

    probes = [
        MagicMock(stdout="8/1", returncode=0),  # avg_frame_rate
        MagicMock(stdout="", returncode=0),  # alpha_mode
        MagicMock(stdout="yuv420p", returncode=0),  # pix_fmt
        MagicMock(stdout=" ... minterpolate ... ", returncode=0),  # ffmpeg -filters
        MagicMock(stdout="", returncode=0, stderr=b""),  # the encode
    ]

    with patch("ops.fps_boost.subprocess.run", side_effect=probes) as mock_run:
        result = boost_fps(str(input_path), output_path, to=16)

    assert result["success"] is True, result["error"]

    encode_cmd = mock_run.call_args_list[4][0][0]
    assert "-vf" in encode_cmd
    filter_arg = encode_cmd[encode_cmd.index("-vf") + 1]
    assert "minterpolate" in filter_arg
    assert "fps=16" in filter_arg
    assert output_path in encode_cmd


def test_boost_fps_actually_raises_the_frame_rate(tmp_path):
    from tests.conftest import make_clip

    clip = make_clip(tmp_path / "clip.mp4", frames=8, fps=8)
    output = tmp_path / "boosted.mp4"

    result = boost_fps(str(clip), str(output), to=16)

    assert result["success"] is True, result["error"]
    assert output.exists()

    probe = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=avg_frame_rate",
            "-of",
            "csv=p=0",
            str(output),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    numerator, _, denominator = probe.stdout.strip().partition("/")
    achieved = float(numerator) / float(denominator or 1)
    assert achieved == pytest.approx(16.0, abs=0.5)
