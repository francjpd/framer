import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import cv2

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from core.parallel import process_video_parallel


@patch("cv2.VideoCapture")
@patch("multiprocessing.Pool")
@patch("subprocess.run")
def test_process_video_parallel(mock_run, mock_pool, mock_videocapture):
    # Setup mock VideoCapture
    mock_cap = MagicMock()
    mock_cap.isOpened.return_value = True
    mock_cap.get.side_effect = lambda prop: {
        cv2.CAP_PROP_FPS: 30,
        cv2.CAP_PROP_FRAME_WIDTH: 100,
        cv2.CAP_PROP_FRAME_HEIGHT: 100,
        cv2.CAP_PROP_FRAME_COUNT: 100
    }.get(prop, 0)
    mock_videocapture.return_value = mock_cap
    
    # Setup mock Pool
    mock_pool_instance = MagicMock()
    mock_pool.return_value.__enter__.return_value = mock_pool_instance
    mock_pool_instance.map.return_value = ["part_0000.mov", "part_0001.mov"]
    
    # Process function
    def dummy_process(frame):
        return frame
        
    result = process_video_parallel(
        input_path="input.mp4",
        output_path="output.mov",
        process_func=dummy_process,
        workers=2
    )
    
    assert result["success"] is True
    assert result["output_path"] == "output.mov"
    
    # Verify pool.map was called
    mock_pool_instance.map.assert_called_once()
    
    # Verify ffmpeg concat command was called
    mock_run.assert_called()
    last_call_args = mock_run.call_args[0][0]
    assert "ffmpeg" in last_call_args
    assert "concat" in last_call_args

@patch("cv2.VideoCapture")
def test_process_video_parallel_invalid_input(mock_videocapture):
    mock_cap = MagicMock()
    mock_cap.isOpened.return_value = False
    mock_videocapture.return_value = mock_cap
    
    result = process_video_parallel(
        input_path="nonexistent.mp4",
        output_path="output.mov",
        process_func=lambda f: f
    )
    
    assert result["success"] is False
    assert "Could not open video" in result["error"]
