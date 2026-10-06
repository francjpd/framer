"""
Shared fixtures for the Python operation tests.

These helpers generate real media with FFmpeg/OpenCV so the operation tests
exercise the actual pipeline rather than only mocks.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import cv2
import numpy as np
import pytest


def _ffmpeg() -> str:
    exe = shutil.which("ffmpeg")
    if exe is None:
        pytest.fail("ffmpeg is required for the operation tests")
    return exe


def make_clip(path: Path, width: int = 32, height: int = 32, frames: int = 8, fps: int = 8) -> Path:
    """Generate a tiny H.264 clip with a moving box."""
    path.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            _ffmpeg(),
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"color=c=0x202020:s={width}x{height}:d=1:r={fps}",
            "-vf",
            "drawbox=x=4:y=4:w=8:h=8:color=red@1:t=fill",
            "-frames:v",
            str(frames),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(f"could not generate test clip: {result.stderr[-1000:]}")
    return path


def make_still(path: Path, width: int = 32, height: int = 32) -> Path:
    """Generate a tiny BGRA still with an opaque box on a transparent field."""
    path.parent.mkdir(parents=True, exist_ok=True)
    image = np.zeros((height, width, 4), dtype=np.uint8)
    image[height // 4 : height // 2, width // 4 : width // 2] = [0, 0, 255, 255]
    if not cv2.imwrite(str(path), image):
        pytest.fail(f"could not write test still: {path}")
    return path


@pytest.fixture
def tiny_clip(tmp_path: Path) -> Path:
    return make_clip(tmp_path / "clip.mp4")


@pytest.fixture
def tiny_still(tmp_path: Path) -> Path:
    return make_still(tmp_path / "still.png")
