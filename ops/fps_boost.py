"""
FPS boost operation - increases video frame rate using FFmpeg.
"""

import subprocess
import shutil
from pathlib import Path
from typing import Dict, Any

from core import register_operation


def boost_fps(input_path: str, output_path: str, to: int = 60) -> Dict[str, Any]:
    """
    Increase video frame rate to target fps using FFmpeg minterpolate.

    Args:
        input_path: Path to input video
        output_path: Path to output video
        to: Target FPS (default: 60)

    Returns:
        dict with success, output_path, error
    """
    result = {"success": False, "output_path": None, "error": None}

    try:
        input_file = Path(input_path)
        if not input_file.exists():
            result["error"] = f"Input file not found: {input_path}"
            return result

        if shutil.which("ffmpeg") is None:
            result["error"] = "FFmpeg not found. Please install FFmpeg."
            return result

        # Get original fps
        fps_cmd = [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-count_frames",
            "-show_entries",
            "stream=avg_frame_rate",
            "-of",
            "csv=p=0",
            str(input_path),
        ]

        fps_result = subprocess.run(fps_cmd, capture_output=True, text=True, check=True)
        original_fps_str = fps_result.stdout.strip()

        # Parse fraction (e.g., "30/1" -> 30.0)
        if "/" in original_fps_str:
            num, denom = original_fps_str.split("/")
            original_fps = float(num) / float(denom)
        else:
            original_fps = float(original_fps_str)

        # Calculate interpolation factor
        if original_fps >= to:
            # No need to interpolate, just copy
            factor = 1
        else:
            factor = to / original_fps
            # Round to nearest integer for cleaner interpolation
            factor = round(factor)

        # Build FFmpeg command
        cmd = ["ffmpeg", "-y", "-i", str(input_path)]

        if factor > 1:
            # Use minterpolate for frame interpolation
            cmd.extend(
                [
                    "-vf",
                    f"minterpolate=fps={to}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1",
                    "-c:v",
                    "libx264",
                    "-preset",
                    "medium",
                    "-crf",
                    "23",
                ]
            )
        else:
            # Just copy or re-encode at target fps
            cmd.extend(["-r", str(to)])

        cmd.append(str(output_path))

        subprocess.run(cmd, capture_output=True, check=True)

        result["success"] = True
        result["output_path"] = str(output_path)
        return result

    except subprocess.CalledProcessError as e:
        result["error"] = f"FFmpeg error: {e.stderr.decode() if e.stderr else str(e)}"
    except Exception as e:
        result["error"] = str(e)

    return result


# Register operation
register_operation(
    name="fps-boost",
    func=boost_fps,
    args_schema={
        "to": {"type": "int", "default": 60, "description": "Target FPS (default: 60)"}
    },
    description="Increase video frame rate to make it smoother",
)
