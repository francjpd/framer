"""
Utility functions for frame operations.
"""

from typing import Union, List, Tuple, Optional
from core.gpu import get_backend, is_available, get_device_info


def get_gpu_info() -> dict:
    """Get information about GPU availability and device."""
    return {
        "backend": get_backend(),
        "available": is_available(),
        "device": get_device_info(),
    }


def parse_color(
    color_str: Union[str, List, Tuple, None], default_alpha: int = 255
) -> Optional[List[int]]:
    """
    Parse color from BGR string, hex, or list/tuple.

    Supports:
    - "transparent" -> [0, 0, 0, 0] (if alpha is requested by caller context, though typically handled via parse_color_rgba)
    - "#RRGGBB" or "#RGB"
    - "B,G,R"

    Returns:
        List of [B, G, R] or None if invalid.
    """
    if color_str is None:
        return None

    if isinstance(color_str, str) and color_str.lower() == "transparent":
        # Special case for transparency, caller should handle appropriately
        return [0, 0, 0, 0]

    if isinstance(color_str, (list, tuple)):
        if len(color_str) >= 3:
            return list(color_str)
        return None

    if isinstance(color_str, str):
        color_str = color_str.strip()
        if color_str.startswith("#"):
            color_str = color_str[1:]

            if len(color_str) == 3:
                try:
                    r = int(color_str[0] * 2, 16)
                    g = int(color_str[1] * 2, 16)
                    b = int(color_str[2] * 2, 16)
                    return [b, g, r]
                except ValueError:
                    pass
            elif len(color_str) == 6:
                try:
                    r = int(color_str[0:2], 16)
                    g = int(color_str[2:4], 16)
                    b = int(color_str[4:6], 16)
                    return [b, g, r]
                except ValueError:
                    pass

        try:
            values = [int(x.strip()) for x in color_str.split(",")]
            if len(values) >= 3:
                # Return B, G, R
                return values[:3]
        except ValueError:
            pass

    return None


def parse_color_rgba(
    color_str: Union[str, List, Tuple, None],
) -> Optional[Tuple[int, int, int, int]]:
    """
    Parse fade color string to RGBA tuple.

    Supports:
    - "transparent" -> (0, 0, 0, 0)
    - "#RRGGBB" or "#RGB" -> (R, G, B, 255)
    - "B,G,R" -> (B, G, R, 255)

    Returns:
        Tuple of (R, G, B, A) or None if invalid.
    """
    if not color_str or (
        isinstance(color_str, str) and color_str.lower() == "transparent"
    ):
        return (0, 0, 0, 0)

    parsed = parse_color(color_str)
    if parsed is None:
        raise ValueError(f"Invalid color format: {color_str}")

    if len(parsed) == 4:
        # If it was transparent [0,0,0,0]
        if parsed == [0, 0, 0, 0]:
            return (0, 0, 0, 0)
        return (parsed[2], parsed[1], parsed[0], parsed[3])

    # parse_color returns [B, G, R], we need to return (R, G, B, 255)
    b, g, r = parsed[:3]
    return (r, g, b, 255)
