import pytest
import numpy as np
import cv2
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from ops.outline import _apply_outline

def test_apply_outline_basic():
    # 50x50 BGRA frame with a 10x10 opaque square in center
    frame = np.zeros((50, 50, 4), dtype=np.uint8)
    frame[20:30, 20:30] = [255, 0, 0, 255] # Blue square
    
    # White outline (BGR: 255, 255, 255), thickness 5
    color_bgr = (255, 255, 255)
    thickness = 5
    
    result = _apply_outline(frame, color_bgr, thickness)
    
    assert result.shape == (50, 50, 4)
    
    # Center should still be blue (within tolerance)
    assert np.all(np.abs(result[25, 25, :3].astype(int) - [255, 0, 0]) <= 2)
    
    # Area just outside should be white (the outline)
    # 20-4 = 16. So (16, 25) should be white.
    assert np.all(np.abs(result[16, 25, :3].astype(int) - [255, 255, 255]) <= 2)
    assert result[16, 25, 3] > 0
    
    # Far away should still be transparent
    assert result[0, 0, 3] == 0

def test_apply_outline_no_alpha():
    # BGR frame should be returned as is
    frame = np.zeros((10, 10, 3), dtype=np.uint8)
    result = _apply_outline(frame, (255, 255, 255), 5)
    assert result.shape == (10, 10, 3)
    assert np.array_equal(result, frame)
