import pytest
import numpy as np
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from core.bg_removal import detect_background_color_from_frame_border

def test_detect_background_color_from_frame_border():
    """Test that we can detect background color from a frame's border."""
    frame = np.full((100, 100, 3), (100, 150, 100), dtype=np.uint8)
    frame[25:75, 25:75] = (200, 100, 50)

    border_color = detect_background_color_from_frame_border(frame, border_width=5)

    assert border_color is not None
    assert len(border_color) == 3
    assert abs(border_color[0] - 100) < 30
    assert abs(border_color[1] - 150) < 30
    assert abs(border_color[2] - 100) < 30
