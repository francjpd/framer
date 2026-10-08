"""
Export operation for web optimization.
Outputs a .webm, .mp4, or highly optimized .gif
"""

import subprocess
from pathlib import Path
from typing import Any

from core import register_operation


def export_web(
    input_path: str, output_dir: str, format: str = "all", 
    fps: int = -1, scale: int = -1, workers: int = 1, progress: bool = False
) -> dict[str, Any]:
    """Export to web-optimized formats."""
    
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    base_name = Path(input_path).stem
    
    formats = ["webm", "mp4", "gif"] if format == "all" else [format]
    
    results = []
    
    for fmt in formats:
        out_path = out_dir / f"{base_name}.{fmt}"
        cmd = ["ffmpeg", "-y", "-threads", str(workers), "-i", str(input_path)]
        
        filters = []
        if fps > 0:
            filters.append(f"fps={fps}")
        if scale > 0:
            filters.append(f"scale={scale}:-1:flags=lanczos")
            
        if fmt == "gif":
            # 2-pass GIF encoding for high quality palette
            palette_path = out_dir / f"{base_name}_palette.png"
            
            # Pass 1: Generate palette
            pal_cmd = ["ffmpeg", "-y", "-i", str(input_path)]
            pal_filters = filters + ["palettegen=stats_mode=diff"]
            if pal_filters:
                pal_cmd.extend(["-vf", ",".join(pal_filters)])
            pal_cmd.append(str(palette_path))
            
            subprocess.run(pal_cmd, check=True, capture_output=not progress)
            
            # Pass 2: Use palette
            cmd = ["ffmpeg", "-y", "-threads", str(workers), "-i", str(input_path), "-i", str(palette_path)]
            use_filters = filters + ["paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"]
            cmd.extend(["-lavfi", ",".join(use_filters)])
            cmd.append(str(out_path))
            
            subprocess.run(cmd, check=True, capture_output=not progress)
            palette_path.unlink() # Cleanup
            
        else:
            if filters:
                cmd.extend(["-vf", ",".join(filters)])
                
            if fmt == "webm":
                cmd.extend(["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-auto-alt-ref", "0"])
            elif fmt == "mp4":
                cmd.extend(["-c:v", "libx264", "-preset", "slow", "-crf", "24", "-pix_fmt", "yuv420p"])
                
            cmd.append(str(out_path))
            subprocess.run(cmd, check=True, capture_output=not progress)
            
        results.append(str(out_path))
        
    return {"success": True, "output_path": ", ".join(results), "error": None}

register_operation(
    name="export",
    func=export_web,
    args_schema={
        "format": {"type": "string", "default": "all", "short": "-f", "description": "Format: webm, mp4, gif, all"},
        "fps": {"type": "int", "default": -1, "description": "Change framerate for export (e.g. 15 for smaller GIFs)"},
        "scale": {"type": "int", "default": -1, "description": "Scale width (keeps aspect ratio)"},
        "workers": {"type": "int", "default": 1, "short": "-w", "description": "Number of threads"},
    },
    description="Export to optimized web formats (gif, webm, mp4)",
)
