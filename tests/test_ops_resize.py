import pytest
import subprocess
from unittest.mock import patch, MagicMock
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from ops.resize import resize_video

@patch("subprocess.run")
def test_resize_video_basic(mock_run):
    # Mock ffprobe calls
    mock_run.return_value = MagicMock(stdout="0", returncode=0)
    
    result = resize_video("in.mp4", "out.mp4", width=1280, height=720)
    
    assert result["success"] is True
    # Verify ffmpeg command
    last_call = mock_run.call_args_list[-1]
    cmd = last_call[0][0]
    full_cmd = " ".join(cmd)
    assert "ffmpeg" in full_cmd
    assert "scale=1280:720" in full_cmd
    assert "out.mp4" in full_cmd

@patch("subprocess.run")
def test_resize_video_pad(mock_run):
    mock_run.return_value = MagicMock(stdout="0", returncode=0)
    
    result = resize_video("in.mp4", "out.mp4", width=1000, height=1000, pad=True)
    
    assert result["success"] is True
    last_call = mock_run.call_args_list[-1]
    cmd = last_call[0][0]
    # Join cmd list into a single string for easier substring matching
    full_cmd = " ".join(cmd)
    assert "force_original_aspect_ratio=decrease" in full_cmd
    assert "pad=1000:1000" in full_cmd

def test_resize_video_no_dims():
    result = resize_video("in.mp4", "out.mp4")
    assert result["success"] is False
    assert "Must specify width or height" in result["error"]
