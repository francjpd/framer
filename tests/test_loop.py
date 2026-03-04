import pytest
import numpy as np
import sys

sys.path.insert(0, "/home/francjpd/projects/bg-remover")

from ops.loop import (
    create_pingpong_loop,
    create_morph_loop,
    create_periodic_loop,
    create_hold_loop,
    create_fade_loop,
    create_blend_loop,
    create_reverse_loop,
    create_speedramp_loop,
    analyze_best_method,
    parse_fade_color,
)


def test_parse_fade_color_transparent():
    result = parse_fade_color("transparent")
    assert result == (0, 0, 0, 0)


def test_parse_fade_color_hex():
    result = parse_fade_color("#FF0000")
    assert result == (255, 0, 0, 255)  # RGB format


def test_parse_fade_color_bgr():
    result = parse_fade_color("0,255,0")
    assert result == (0, 255, 0, 255)


def test_pingpong_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_pingpong_loop(frames)
    assert len(result) == 19  # forward (10) + backward without duplicate (9)
    assert np.array_equal(result[0], frames[0])
    assert np.array_equal(result[-1], frames[0])


def test_reverse_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_reverse_loop(frames)
    assert len(result) == 20
    assert np.array_equal(result[0], frames[0])
    assert np.array_equal(result[-1], frames[0])


def test_hold_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_hold_loop(frames, hold_frames=2)
    assert len(result) == 12  # 10 original + 2 hold frames


def test_fade_loop_transparent():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(20)]
    result = create_fade_loop(frames, fade_color="transparent", fade_frames=5)
    assert len(result) == 20


def test_blend_loop_add():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_blend_loop(frames, blend_mode="add")
    assert len(result) == 15  # 10 original + 5 blended transition frames


def test_speedramp_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_speedramp_loop(frames, ramp_factor=1.0)
    assert len(result) >= 10


def test_analyze_best_method_returns_dict():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(20)]
    result = analyze_best_method(frames)
    assert isinstance(result, dict)
    assert "recommended" in result
