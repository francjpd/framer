import pytest
import json
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from ops.remove_bg import remove_bg

@patch("ops.remove_bg._remove_background")
def test_remove_bg_basic(mock_internal):
    mock_internal.return_value = {"success": True, "output_path": "out.mov", "error": None}
    
    result = remove_bg("in.mp4", "out.mov", color="#00FF00", tolerance=20)
    
    assert result["success"] is True
    mock_internal.assert_called_once()
    args, kwargs = mock_internal.call_args
    assert kwargs["background_color"] == [0, 255, 0] # Hex #00FF00 to BGR
    assert kwargs["tolerance"] == 20

@patch("ops.remove_bg._remove_background")
def test_remove_bg_config(mock_internal, tmp_path):
    mock_internal.return_value = {"success": True, "output_path": "out.mov", "error": None}
    
    config_file = tmp_path / "test_config.json"
    config_data = {
        "bg": {
            "color": "#FF0000",
            "tolerance": 40,
            "edges": 10,
            "workers": 4
        }
    }
    with open(config_file, "w") as f:
        json.dump(config_data, f)
        
    result = remove_bg("in.mp4", "out.mov", config=str(config_file))
    
    assert result["success"] is True
    args, kwargs = mock_internal.call_args
    assert kwargs["background_color"] == [0, 0, 255] # Hex #FF0000 to BGR
    assert kwargs["tolerance"] == 40
    assert kwargs["soft_edges"] == 10
    assert kwargs["workers"] == 4
