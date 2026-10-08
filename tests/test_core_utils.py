import sys
from pathlib import Path

import pytest

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from core.utils import parse_color, parse_color_rgba


def test_parse_color_hex():
    # Hex to BGR
    assert parse_color("#FF0000") == [0, 0, 255]  # Red: B=0, G=0, R=255
    assert parse_color("#00FF00") == [0, 255, 0]  # Green: B=0, G=255, R=0
    assert parse_color("#0000FF") == [255, 0, 0]  # Blue: B=255, G=0, R=0
    assert parse_color("#FFF") == [255, 255, 255] # White
    assert parse_color("#000") == [0, 0, 0]       # Black

def test_parse_color_csv():
    assert parse_color("10,20,30") == [10, 20, 30] # B, G, R
    assert parse_color(" 255, 128, 64 ") == [255, 128, 64]

def test_parse_color_transparent():
    assert parse_color("transparent") == [0, 0, 0, 0]

def test_parse_color_list_tuple():
    assert parse_color([10, 20, 30]) == [10, 20, 30]
    assert parse_color((10, 20, 30, 255)) == [10, 20, 30, 255]

def test_parse_color_invalid():
    assert parse_color("invalid") is None
    assert parse_color("#GGGGGG") is None
    assert parse_color("1,2") is None
    assert parse_color(None) is None

def test_parse_color_rgba():
    # parse_color_rgba converts BGR/Hex to RGBA (R, G, B, A)
    assert parse_color_rgba("#FF0000") == (255, 0, 0, 255) # R, G, B, A
    # CSV "0,255,0" is B=0, G=255, R=0 -> (0, 255, 0, 255)
    assert parse_color_rgba("0,255,0") == (0, 255, 0, 255)
    assert parse_color_rgba("transparent") == (0, 0, 0, 0)
    assert parse_color_rgba(None) == (0, 0, 0, 0)

def test_parse_color_rgba_invalid():
    with pytest.raises(ValueError):
        parse_color_rgba("invalid")
