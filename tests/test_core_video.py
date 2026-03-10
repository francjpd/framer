import pytest
import numpy as np
import subprocess
from unittest.mock import patch, MagicMock
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from core.video import VideoStreamReader, VideoStreamWriter, get_output_format

def test_get_output_format():
    assert get_output_format("test.webm") == "webm"
    assert get_output_format("test.gif") == "gif"
    assert get_output_format("test.mp4") == "mp4"
    assert get_output_format("test.mov") == "mov"
    assert get_output_format("test.avi") == "mov"  # Default
    assert get_output_format("test.avi", format_flag="webm") == "webm"

@patch("subprocess.Popen")
def test_video_stream_reader_init(mock_popen):
    mock_process = MagicMock()
    mock_process.returncode = 0
    mock_popen.return_value = mock_process
    
    with VideoStreamReader("input.mp4", fps=30, width=100, height=100) as reader:
        assert reader.input_path == "input.mp4"
        assert reader.channels == 3
        
    # Verify ffmpeg command
    args, kwargs = mock_popen.call_args
    cmd = args[0]
    assert "ffmpeg" in cmd
    assert "input.mp4" in cmd
    assert "image2pipe" in cmd
    assert "bgr24" in cmd

@patch("subprocess.Popen")
def test_video_stream_reader_read(mock_popen):
    mock_process = MagicMock()
    # Mock stdout.read to return 100*100*3 bytes of zeros
    mock_process.stdout.read.return_value = b"\x00" * (100 * 100 * 3)
    mock_popen.return_value = mock_process
    
    reader = VideoStreamReader("input.mp4", fps=30, width=100, height=100)
    frame = reader.read_frame()
    
    assert frame is not None
    assert frame.shape == (100, 100, 3)
    assert np.all(frame == 0)

@patch("subprocess.Popen")
def test_video_stream_writer_init(mock_popen):
    mock_process = MagicMock()
    mock_process.returncode = 0
    mock_popen.return_value = mock_process
    
    with VideoStreamWriter("output.webm", fps=30, width=100, height=100, has_alpha=True) as writer:
        assert writer.output_path == "output.webm"
        assert writer.format == "webm"
        
    # Verify ffmpeg command
    args, kwargs = mock_popen.call_args
    cmd = args[0]
    assert "ffmpeg" in cmd
    assert "output.webm" in cmd
    assert "libvpx-vp9" in cmd
    assert "yuva420p" in cmd

@patch("subprocess.Popen")
def test_video_stream_writer_write(mock_popen):
    mock_process = MagicMock()
    mock_process.returncode = 0
    mock_popen.return_value = mock_process
    
    writer = VideoStreamWriter("output.mp4", fps=30, width=100, height=100)
    frame = np.zeros((100, 100, 3), dtype=np.uint8)
    writer.write_frame(frame)
    
    mock_process.stdin.write.assert_called_once()
    # Check that it wrote the correct number of bytes
    written_bytes = mock_process.stdin.write.call_args[0][0]
    assert len(written_bytes) == 100 * 100 * 3
