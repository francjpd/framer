import sys
from pathlib import Path

import numpy as np

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from ops.glow import _apply_glow


def test_apply_glow_basic():
    # 50x50 BGRA frame with a 10x10 opaque square in center
    frame = np.zeros((50, 50, 4), dtype=np.uint8)
    frame[20:30, 20:30] = [0, 0, 255, 255] # Red square
    
    # White glow (BGR: 255, 255, 255), radius 5
    color_bgr = (255, 255, 255)
    radius = 5
    intensity = 1.0
    
    result = _apply_glow(frame, color_bgr, radius, intensity)
    
    assert result.shape == (50, 50, 4)
    
    # Center should still be red (within tolerance)
    assert np.all(np.abs(result[25, 25, :3].astype(int) - [0, 0, 255]) <= 2)
    
    # Area just outside should have some white glow (alpha > 0)
    assert result[18, 18, 3] > 0
    # Glow should have white color components mixed in
    assert result[18, 18, 0] > 0
    
    # Far away should still be transparent (Gaussian blur fades off)
    assert result[0, 0, 3] < 10

def test_apply_glow_no_alpha():
    # BGR frame should be returned as is
    frame = np.zeros((10, 10, 3), dtype=np.uint8)
    result = _apply_glow(frame, (255, 255, 255), 5, 1.0)
    assert result.shape == (10, 10, 3)
    assert np.array_equal(result, frame)
