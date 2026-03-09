"""
Resize / scale operation using FFmpeg.
"""

import subprocess
from pathlib import Path
from typing import Dict, Any

from core import register_operation

def resize_video(
    input_path: str, output_path: str, width: int = -1, height: int = -1, 
    pad: bool = False, workers: int = 1, progress: bool = False
) -> Dict[str, Any]:
    """Resize/scale video."""
    
    if width == -1 and height == -1:
        return {"success": False, "output_path": None, "error": "Must specify width or height"}
        
    cmd = ["ffmpeg", "-y", "-threads", str(workers), "-i", str(input_path)]
    
    # Scale filter
    scale_str = f"scale={width}:{height}"
    
    # If pad is true, we scale to fit within dimensions, then pad with transparency
    if pad and width != -1 and height != -1:
        scale_str = f"scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black@0"
        
    # Check for alpha
    alpha_cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream_tags=alpha_mode", "-of", "csv=p=0", str(input_path)
    ]
    alpha_result = subprocess.run(alpha_cmd, capture_output=True, text=True)
    has_alpha = "1" in alpha_result.stdout

    if not has_alpha:
        pix_fmt_cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=pix_fmt", "-of", "csv=p=0", str(input_path)
        ]
        pix_fmt_result = subprocess.run(pix_fmt_cmd, capture_output=True, text=True)
        has_alpha = any(x in pix_fmt_result.stdout for x in ["yuva", "bgra", "argb", "gba", "rgba"])
        
    cmd.extend(["-vf", scale_str])
    
    # Codec setup
    out_ext = Path(output_path).suffix.lower()
    if out_ext == ".webm":
        cmd.extend(["-c:v", "libvpx-vp9", "-auto-alt-ref", "0"])
        if has_alpha:
            cmd.extend(["-pix_fmt", "yuva420p"])
    elif out_ext == ".mov":
        cmd.extend(["-c:v", "qtrle"])
        if has_alpha:
            cmd.extend(["-pix_fmt", "yuva420p"])
    else:
        cmd.extend(["-c:v", "libx264"])
        
    cmd.append(str(output_path))
    
    try:
        if progress:
            print("Resizing video...")
        subprocess.run(cmd, check=True, capture_output=not progress)
        if progress:
            print("Done!")
        return {"success": True, "output_path": output_path, "error": None}
    except subprocess.CalledProcessError as e:
        return {"success": False, "output_path": None, "error": str(e)}

register_operation(
    name="resize",
    func=resize_video,
    args_schema={
        "width": {"type": "int", "default": -1, "short": "-W", "description": "Target width (-1 to keep aspect ratio)"},
        "height": {"type": "int", "default": -1, "short": "-H", "description": "Target height (-1 to keep aspect ratio)"},
        "pad": {"type": "bool", "default": False, "description": "Pad with transparency if aspect ratio changes"},
        "workers": {"type": "int", "default": 1, "short": "-w", "description": "Number of threads"},
    },
    description="Resize or scale a video",
)
