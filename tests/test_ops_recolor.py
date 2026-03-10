import pytest
import numpy as np
import cv2
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from ops.recolor import _apply_recolor

def test_apply_recolor():
    # BGR frame (10x10)
    frame = np.zeros((10, 10, 3), dtype=np.uint8)
    frame[:] = [0, 255, 0] # Pure green
    frame[5, 5] = [0, 0, 255] # Red pixel
    
    # Recolor green to blue
    target_bgr = [0, 255, 0]
    new_bgr = [255, 0, 0] # Pure blue
    tolerance = 10
    
    result = _apply_recolor(frame, tuple(target_bgr), tuple(new_bgr), tolerance)
    
    assert result[0, 0, 0] == 255 # Now blue
    assert result[0, 0, 1] == 0
    assert result[0, 0, 2] == 0
    
    assert result[5, 5, 2] == 255 # Red pixel should still be red
    assert result[5, 5, 0] == 0

def test_apply_recolor_rgba():
    # BGRA frame
    frame = np.zeros((10, 10, 4), dtype=np.uint8)
    frame[:] = [0, 255, 0, 128] # Semi-transparent green
    
    target_bgr = [0, 255, 0]
    new_bgr = [0, 0, 255] # Red
    
    result = _apply_recolor(frame, tuple(target_bgr), tuple(new_bgr), 10)
    
    assert result[0, 0, 0] == 0
    assert result[0, 0, 1] == 0
    assert result[0, 0, 2] == 255
    assert result[0, 0, 3] == 128 # Alpha should be preserved
