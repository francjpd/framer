"""
Glow / Drop-shadow operation.
Adds a soft glowing aura behind objects with an alpha channel.
"""

import cv2
import numpy as np
from typing import Dict, Any

from core import register_operation
from core.parallel import process_video_parallel
from core.utils import parse_color
from core.video import has_alpha_channel

def _apply_glow(frame: np.ndarray, color_bgr: tuple, radius: int, intensity: float) -> np.ndarray:
    """
    Frame processing function for glow.
    """
    if frame.shape[2] != 4:
        return frame

    b, g, r, a = cv2.split(frame)
    
    # Create the glow mask by blurring the alpha channel
    # Blur kernel size must be odd
    kernel_size = radius * 2 + 1
    glow_alpha = cv2.GaussianBlur(a, (kernel_size, kernel_size), 0)
    
    # Increase intensity
    if intensity != 1.0:
        glow_alpha = np.clip(glow_alpha.astype(float) * intensity, 0, 255).astype(np.uint8)
    
    # Create background glow layer
    bg_layer = np.zeros_like(frame)
    bg_layer[:, :, 0] = color_bgr[0]
    bg_layer[:, :, 1] = color_bgr[1]
    bg_layer[:, :, 2] = color_bgr[2]
    bg_layer[:, :, 3] = glow_alpha
    
    # Composite original frame over glow layer
    alpha_fg = a.astype(float) / 255.0
    alpha_bg = glow_alpha.astype(float) / 255.0
    
    out_alpha = alpha_fg + alpha_bg * (1 - alpha_fg)
    
    out_color = np.zeros_like(frame[:, :, :3], dtype=float)
    for c in range(3):
        out_color[:, :, c] = (frame[:, :, c] * alpha_fg + bg_layer[:, :, c] * alpha_bg * (1 - alpha_fg)) / (out_alpha + 1e-6)
        
    out_frame = np.zeros_like(frame)
    out_frame[:, :, :3] = np.clip(out_color, 0, 255).astype(np.uint8)
    out_frame[:, :, 3] = np.clip(out_alpha * 255, 0, 255).astype(np.uint8)
    
    return out_frame

def add_glow(
    input_path: str, output_path: str, color: str = "#FFFFFF", radius: int = 15,
    intensity: float = 1.0, workers: int = None, progress: bool = False
) -> Dict[str, Any]:
    """Add a soft glow/drop-shadow to a transparent video."""
    
    if not has_alpha_channel(input_path):
        return {
            "success": False, 
            "output_path": None, 
            "error": "Input video does not have an alpha channel. Please run 'remove-bg' first."
        }
        
    bgr_color = parse_color(color)
    
    result = process_video_parallel(
        input_path=input_path,
        output_path=output_path,
        process_func=_apply_glow,
        func_kwargs={"color_bgr": bgr_color, "radius": radius, "intensity": intensity},
        workers=workers,
        show_progress=progress
    )
    
    return result

register_operation(
    name="glow",
    func=add_glow,
    args_schema={
        "color": {"type": "string", "default": "#FFFFFF", "short": "-c", "description": "Glow color"},
        "radius": {"type": "int", "default": 15, "short": "-r", "description": "Blur radius size"},
        "intensity": {"type": "float", "default": 1.0, "short": "-i", "description": "Brightness multiplier"},
        "workers": {"type": "int", "default": 1, "short": "-w", "description": "Number of worker threads"},
    },
    description="Add a soft glow behind an object with a transparent background",
)
