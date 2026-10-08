import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from ops.trim import trim_video


@patch("subprocess.run")
def test_trim_video_basic(mock_run):
    mock_run.return_value = MagicMock(returncode=0)
    
    result = trim_video("in.mp4", "out.mp4", start=1.5, end=5.0)
    
    assert result["success"] is True
    # Verify ffmpeg command
    args, _kwargs = mock_run.call_args
    cmd = args[0]
    assert "-ss" in cmd
    assert "1.5" in cmd
    assert "-to" in cmd
    assert "5.0" in cmd

@patch("subprocess.run")
def test_trim_video_duration(mock_run):
    mock_run.return_value = MagicMock(returncode=0)
    
    result = trim_video("in.mp4", "out.mp4", start=10.0, duration=2.5)
    
    assert result["success"] is True
    args, _kwargs = mock_run.call_args
    cmd = args[0]
    assert "-ss" in cmd
    assert "10.0" in cmd
    assert "-t" in cmd
    assert "2.5" in cmd
