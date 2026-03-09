"""
Outline operation - adds a colored border around objects with an alpha channel.
"""

import subprocess
import cv2
import numpy as np
from typing import Dict, Any

from core import register_operation
from core.parallel import process_video_parallel
from core.utils import parse_color

def check_alpha_channel(video_path: str) -> bool:
    """Check if the video has an alpha channel using ffprobe."""
    try:
        alpha_cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream_tags=alpha_mode", "-of", "csv=p=0", video_path
        ]
        alpha_result = subprocess.run(alpha_cmd, capture_output=True, text=True)
        if "1" in alpha_result.stdout:
            return True

        pix_fmt_cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=pix_fmt", "-of", "csv=p=0", video_path
        ]
        pix_fmt_result = subprocess.run(pix_fmt_cmd, capture_output=True, text=True)
        pix_fmt = pix_fmt_result.stdout.strip()
        return any(x in pix_fmt for x in ["yuva", "bgra", "argb", "gba", "rgba"])
    except Exception:
        return False

def _apply_outline(frame: np.ndarray, color_bgr: tuple, thickness: int) -> np.ndarray:
    """
    Frame processing function for outline.
    frame is expected to be BGRA.
    """
    # If frame has no alpha channel, just return it
    if frame.shape[2] != 4:
        return frame

    b, g, r, a = cv2.split(frame)
    
    # Create kernel for dilation
    kernel_size = 2 * thickness + 1
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel_size, kernel_size))
    
    # Dilate the alpha channel
    dilated_alpha = cv2.dilate(a, kernel, iterations=1)
    
    # The outline area is the difference between dilated alpha and original alpha
    # But for smoother edges, we can use the dilated alpha as the background layer's alpha
    
    # Create the solid color background layer
    bg_layer = np.zeros_like(frame)
    bg_layer[:, :, 0] = color_bgr[0]
    bg_layer[:, :, 1] = color_bgr[1]
    bg_layer[:, :, 2] = color_bgr[2]
    bg_layer[:, :, 3] = dilated_alpha
    
    # Composite the original frame over the background layer
    # Normalize alphas
    alpha_fg = a.astype(float) / 255.0
    alpha_bg = dilated_alpha.astype(float) / 255.0
    
    # Output alpha
    out_alpha = alpha_fg + alpha_bg * (1 - alpha_fg)
    
    # Output RGB
    out_color = np.zeros_like(frame[:, :, :3], dtype=float)
    for c in range(3):
        out_color[:, :, c] = (frame[:, :, c] * alpha_fg + bg_layer[:, :, c] * alpha_bg * (1 - alpha_fg)) / (out_alpha + 1e-6)
        
    out_frame = np.zeros_like(frame)
    out_frame[:, :, :3] = np.clip(out_color, 0, 255).astype(np.uint8)
    out_frame[:, :, 3] = np.clip(out_alpha * 255, 0, 255).astype(np.uint8)
    
    return out_frame

def add_outline(
    input_path: str, output_path: str, color: str = "#FFFFFF", thickness: int = 5,
    workers: int = None, progress: bool = False
) -> Dict[str, Any]:
    """Add a solid outline around objects in an alpha-channel video."""
    
    if not check_alpha_channel(input_path):
        return {
            "success": False, 
            "output_path": None, 
            "error": "Input video does not have an alpha channel (transparent background). Please run 'remove-bg' on it first."
        }
        
    # Parse color (defaults to BGR for cv2)
    bgr_color = parse_color(color)
    
    result = process_video_parallel(
        input_path=input_path,
        output_path=output_path,
        process_func=_apply_outline,
        func_kwargs={"color_bgr": bgr_color, "thickness": thickness},
        workers=workers,
        show_progress=progress
    )
    
    return result

register_operation(
    name="outline",
    func=add_outline,
    args_schema={
        "color": {"type": "string", "default": "#FFFFFF", "short": "-c", "description": "Outline color (hex or BGR)"},
        "thickness": {"type": "int", "default": 5, "short": "-t", "description": "Outline thickness in pixels"},
        "workers": {"type": "int", "default": 1, "short": "-w", "description": "Number of worker threads"},
    },
    description="Add a solid outline to a video with a transparent background",
)
