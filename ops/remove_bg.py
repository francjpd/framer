"""
Remove background operation - removes background from video with alpha channel.
"""

import sys
import json
from pathlib import Path
from typing import Dict, Any

from core import register_operation

# Import existing functionality
sys.path.insert(0, str(Path(__file__).parent.parent))
from bgremover import remove_background as _remove_background


def remove_bg(
    input_path: str,
    output_path: str,
    color: str | None = None,
    tolerance: int = 30,
    edges: int = 5,
    auto_ranges: bool = True,
    num_ranges: int = 5,
    method: str = "color",
    motion_frames: int = 30,
    edge_cleanup: int = 3,
    adaptive_bg: bool = False,
    refine: bool = False,
    refine_tolerance: int = 45,
    refine_block_size: int = 32,
    loop: bool = True,
    config: str | None = None,
) -> Dict[str, Any]:
    """
    Remove background from video.

    Args:
        input_path: Path to input video
        output_path: Path to output video
        color: Background color (BGR: "0,255,0", hex: "#00FF00")
        tolerance: Color tolerance (default: 30)
        edges: Soft edge size (default: 5)
        auto_ranges: Auto-generate color ranges (default: True)
        num_ranges: Number of auto-generated ranges (default: 5)
        method: Detection method - color, motion, combined (default: color)
        motion_frames: Frames for motion detection (default: 30)
        edge_cleanup: Edge cleanup pixels (default: 3)
        adaptive_bg: Adaptive background detection (default: False)
        refine: Enable refinement pass (default: False)
        refine_tolerance: Refinement tolerance (default: 45)
        refine_block_size: Refinement block size (default: 32)
        loop: Enable infinite loop (default: True)
        config: Path to config JSON file (exclusive - no other args allowed)

    Returns:
        dict with success, output_path, error
    """
    # Load config if provided
    if config:
        config_path = Path(config)
        if not config_path.exists():
            return {
                "success": False,
                "output_path": None,
                "error": f"Config file not found: {config}",
            }

        with open(config_path) as f:
            config_data = json.load(f)

        # Get bg options from config
        bg_options = config_data.get("bg", {})
        color = bg_options.get("color", color)
        tolerance = bg_options.get("tolerance", tolerance)
        edges = bg_options.get("edges", edges)
        auto_ranges = bg_options.get("auto_ranges", auto_ranges)
        num_ranges = bg_options.get("num_ranges", num_ranges)
        method = bg_options.get("method", method)
        motion_frames = bg_options.get("motion_frames", motion_frames)
        edge_cleanup = bg_options.get("edge_cleanup", edge_cleanup)
        adaptive_bg = bg_options.get("adaptive_bg", adaptive_bg)
        refine = bg_options.get("refine", refine)
        refine_tolerance = bg_options.get("refine_tolerance", refine_tolerance)
        refine_block_size = bg_options.get("refine_block_size", refine_block_size)
        loop = bg_options.get("loop", loop)

    # Parse color
    bg_color = None
    if color:
        bg_color = _parse_color(color)

    # Call existing function
    return _remove_background(
        input_path=input_path,
        output_path=output_path,
        background_color=bg_color,
        tolerance=tolerance,
        soft_edges=edges,
        show_progress=False,
        auto_ranges=auto_ranges,
        num_ranges=num_ranges,
        method=method,
        motion_frames=motion_frames,
        edge_cleanup=edge_cleanup,
        adaptive_bg=adaptive_bg,
        refine=refine,
        refine_tolerance=refine_tolerance,
        refine_block_size=refine_block_size,
        loop=loop,
    )

    # Handle result
    return result


def _parse_color(color_str: str):
    """Parse color from BGR string or hex."""
    if color_str is None:
        return None

    color_str = color_str.strip()
    if color_str.startswith("#"):
        color_str = color_str[1:]

    if len(color_str) == 6:
        try:
            r = int(color_str[0:2], 16)
            g = int(color_str[2:4], 16)
            b = int(color_str[4:6], 16)
            return [b, g, r]
        except ValueError:
            pass

    try:
        values = [int(x.strip()) for x in color_str.split(",")]
        if len(values) == 3:
            return values
    except ValueError:
        pass

    return None


# Register operation
register_operation(
    name="remove-bg",
    func=remove_bg,
    args_schema={
        "color": {
            "type": "string",
            "default": None,
            "description": "Background color (BGR: '0,255,0', hex: '#00FF00')",
        },
        "tolerance": {
            "type": "int",
            "default": 30,
            "description": "Color tolerance (default: 30)",
        },
        "edges": {
            "type": "int",
            "default": 5,
            "description": "Soft edge size (default: 5)",
        },
        "auto_ranges": {
            "type": "bool",
            "default": True,
            "description": "Auto-generate color ranges",
        },
        "num_ranges": {
            "type": "int",
            "default": 5,
            "description": "Number of auto-generated ranges",
        },
        "method": {
            "type": "string",
            "default": "color",
            "description": "Detection method: color, motion, combined",
        },
        "config": {
            "type": "string",
            "default": None,
            "description": "Path to config JSON file (exclusive)",
        },
    },
    description="Remove background from video with alpha channel",
)
