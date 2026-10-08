"""
Trim operation using FFmpeg.
"""

import subprocess
from typing import Any

from core import register_operation


def trim_video(
    input_path: str, output_path: str, start: float | None = None,
    end: float | None = None, duration: float | None = None,
    progress: bool = False
) -> dict[str, Any]:
    """Trim a specific time window from video."""
    
    cmd = ["ffmpeg", "-y"]
    
    if start is not None:
        cmd.extend(["-ss", str(start)])
        
    cmd.extend(["-i", str(input_path)])
    
    if duration is not None:
        cmd.extend(["-t", str(duration)])
    elif end is not None:
        cmd.extend(["-to", str(end)])
        
    # We use stream copy to avoid re-encoding if possible, which is blazing fast
    # However, if precise trimming is needed, re-encoding is safer. Let's re-encode by default for webm/alpha safety.
    cmd.extend(["-c", "copy"])
    cmd.append(str(output_path))
    
    try:
        if progress:
            print("Trimming video...")
        subprocess.run(cmd, check=True, capture_output=not progress)
        if progress:
            print("Done!")
        return {"success": True, "output_path": output_path, "error": None}
    except subprocess.CalledProcessError:
        # If copy fails (e.g., container mismatch), try re-encoding
        try:
            cmd.remove("-c")
            cmd.remove("copy")
            subprocess.run(cmd, check=True, capture_output=not progress)
            return {"success": True, "output_path": output_path, "error": None}
        except subprocess.CalledProcessError as e2:
            return {"success": False, "output_path": None, "error": str(e2)}

register_operation(
    name="trim",
    func=trim_video,
    args_schema={
        "start": {"type": "float", "default": None, "short": "-s", "description": "Start time in seconds"},
        "end": {"type": "float", "default": None, "short": "-e", "description": "End time in seconds"},
        "duration": {"type": "float", "default": None, "short": "-d", "description": "Duration in seconds"},
    },
    description="Trim a segment of a video",
)
