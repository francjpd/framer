"""
Recolor / Tint operation.
Replaces a specific color (or range of colors) with a new color.
"""

import cv2
import numpy as np
from typing import Dict, Any

from core import register_operation
from core.parallel import process_video_parallel
from core.utils import parse_color

def _apply_recolor(frame: np.ndarray, target_bgr: tuple, new_bgr: tuple, tolerance: int) -> np.ndarray:
    """
    Frame processing function for recoloring.
    """
    # Create mask for pixels within tolerance of target color
    lower_bound = np.array([max(0, c - tolerance) for c in target_bgr], dtype=np.uint8)
    upper_bound = np.array([min(255, c + tolerance) for c in target_bgr], dtype=np.uint8)
    
    # We only care about RGB channels for the mask
    bgr_frame = frame[:, :, :3]
    mask = cv2.inRange(bgr_frame, lower_bound, upper_bound)
    
    # If no pixels match, return original frame
    if cv2.countNonZero(mask) == 0:
        return frame
        
    # Create an output frame
    out_frame = frame.copy()
    
    # For a simple solid tint, we can just replace the pixels where mask > 0
    # A more advanced version would preserve luminance (brightness)
    
    # Simple replacement:
    out_frame[mask > 0, 0] = new_bgr[0]
    out_frame[mask > 0, 1] = new_bgr[1]
    out_frame[mask > 0, 2] = new_bgr[2]
    
    return out_frame

def recolor_video(
    input_path: str, output_path: str, target: str, new_color: str,
    tolerance: int = 30, workers: int = None, progress: bool = False
) -> Dict[str, Any]:
    """Replace a target color with a new color in the video."""
    
    target_bgr = parse_color(target)
    new_bgr = parse_color(new_color)
    
    result = process_video_parallel(
        input_path=input_path,
        output_path=output_path,
        process_func=_apply_recolor,
        func_kwargs={"target_bgr": target_bgr, "new_bgr": new_bgr, "tolerance": tolerance},
        workers=workers,
        show_progress=progress
    )
    
    return result

register_operation(
    name="recolor",
    func=recolor_video,
    args_schema={
        "target": {"type": "string", "short": "-t", "description": "Target color to replace (hex or BGR)"},
        "new_color": {"type": "string", "short": "-n", "description": "New color to apply (hex or BGR)"},
        "tolerance": {"type": "int", "default": 30, "description": "Color matching tolerance"},
        "workers": {"type": "int", "default": 1, "short": "-w", "description": "Number of worker threads"},
    },
    description="Replace a specific color or color range with a new color",
)
