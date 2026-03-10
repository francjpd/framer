import pytest
import numpy as np
import cv2
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from core.bg_removal import (
    generate_color_ranges,
    _color_distance,
    _cluster_colors,
    detect_background_color_from_frame_border,
    _apply_soft_edges,
    _apply_edge_cleanup,
    _process_frame,
    VideoBackgroundRemover
)

def test_generate_color_ranges():
    base_color = [100, 150, 200]
    ranges = generate_color_ranges(base_color, num_ranges=3)
    assert len(ranges) == 3
    assert ranges[0]["color"] == base_color
    assert "tolerance" in ranges[0]

def test_color_distance():
    c1 = [0, 0, 0]
    c2 = [0, 0, 10]
    assert _color_distance(c1, c2) == 10.0
    
    c3 = [3, 4, 0]
    assert _color_distance(c1, c3) == 5.0

def test_cluster_colors():
    colors = [(10, 10, 10), (11, 11, 11), (100, 100, 100), (101, 101, 101)]
    clusters = _cluster_colors(colors, tolerance=5)
    assert len(clusters) == 2
    # Check if they are grouped correctly
    assert (10, 10, 10) in clusters or (11, 11, 11) in clusters or (10, 10, 10) == clusters[0]

def test_detect_background_color_from_frame_border():
    # Create a frame with a solid border color
    bg_color = [50, 100, 150]
    frame = np.zeros((100, 100, 3), dtype=np.uint8)
    # Fill border
    frame[:10, :] = bg_color
    frame[-10:, :] = bg_color
    frame[:, :10] = bg_color
    frame[:, -10:] = bg_color
    # Fill center with something else
    frame[20:80, 20:80] = [200, 200, 200]
    
    detected = detect_background_color_from_frame_border(frame, border_width=5)
    assert detected == bg_color

def test_apply_soft_edges():
    mask = np.zeros((20, 20), dtype=np.uint8)
    mask[5:15, 5:15] = 255
    
    soft = _apply_soft_edges(mask, soft_edges=2)
    assert soft.shape == mask.shape
    assert soft.dtype == np.uint8
    # Should have some intermediate values (not just 0 and 255)
    unique_vals = np.unique(soft)
    assert len(unique_vals) > 2

def test_apply_edge_cleanup():
    mask = np.zeros((20, 20), dtype=np.uint8)
    mask[5:15, 5:15] = 255
    # Add a small noise pixel
    mask[2, 2] = 255
    
    cleaned = _apply_edge_cleanup(mask, edge_cleanup=1)
    assert cleaned[2, 2] == 0
    # The main box should be smaller
    assert cleaned[5, 5] == 0 
    assert cleaned[6, 6] == 255

def test_process_frame_color_removal():
    frame = np.zeros((100, 100, 3), dtype=np.uint8)
    bg_color = [0, 255, 0] # Green
    fg_color = [0, 0, 255] # Red
    
    frame[:] = bg_color
    frame[40:60, 40:60] = fg_color
    
    color_ranges = [{"color": bg_color, "tolerance": 10}]
    # _process_frame returns the FOREGROUND mask (where things were NOT removed)
    fg_mask = _process_frame(frame, color_ranges)
    
    assert fg_mask[50, 50] == 255 # Foreground should be preserved
    assert fg_mask[10, 10] == 0   # Background should be removed

def test_video_background_remover_hsv():
    remover = VideoBackgroundRemover(color_space="hsv")
    # Pure Green BGR is [0, 255, 0]
    remover.add_color_range([0, 255, 0], tolerance=10, soft_edges=0)
    
    frame = np.zeros((10, 10, 3), dtype=np.uint8)
    frame[:] = [0, 255, 0] # Green
    frame[4:6, 4:6] = [0, 0, 255] # Red
    
    processed = remover.process_frame(frame)
    assert processed.shape == (10, 10, 4) # Should have alpha
    
    # In VideoBackgroundRemover, alpha 255 = target color detected.
    assert processed[0, 0, 3] == 255 # Green was target
    assert processed[5, 5, 3] == 0   # Red was not target
