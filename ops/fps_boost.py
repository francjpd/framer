"""
FPS boost operation - increases video frame rate using FFmpeg.
"""

import subprocess
import shutil
from pathlib import Path
from typing import Dict, Any

from core import register_operation


def boost_fps(
    input_path: str, output_path: str, to: int = 60, progress: bool = False
) -> Dict[str, Any]:
    """
    Increase video frame rate to target fps using FFmpeg.

    Tries minterpolate filter first, falls back to simple framerate conversion
    if minterpolate is not available or if the original fps already matches target.

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

        # Check if input has alpha channel
        # VP9 with alpha reports pix_fmt=yuv420p but has alpha_mode=1 in tags
        # So we need to check both alpha_mode (as tag) and pix_fmt
        alpha_cmd = [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream_tags=alpha_mode",
            "-of",
            "csv=p=0",
            str(input_path),
        ]
        alpha_result = subprocess.run(alpha_cmd, capture_output=True, text=True)
        has_alpha = "1" in alpha_result.stdout

        # Also check pix_fmt as fallback for other formats
        pix_fmt_cmd = [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=pix_fmt",
            "-of",
            "csv=p=0",
            str(input_path),
        ]
        pix_fmt_result = subprocess.run(pix_fmt_cmd, capture_output=True, text=True)
        input_pix_fmt = pix_fmt_result.stdout.strip()
        has_alpha = has_alpha or (
            "yuva" in input_pix_fmt
            or "bgra" in input_pix_fmt
            or "argb" in input_pix_fmt
            or "gba" in input_pix_fmt
        )

        # Determine output format from extension
        output_ext = Path(output_path).suffix.lower()

        # Warn if output to mp4 which doesn't support alpha
        if has_alpha and output_ext == ".mp4":
            result["error"] = (
                "MP4 does not support alpha channel. Use .webm or .mov for output with alpha."
            )
            return result

        # Choose codec based on format (always set before building command)
        if output_ext in [".webm"]:
            video_codec = "libvpx-vp9"
            codec_args = [
                "-c:v",
                video_codec,
                "-pix_fmt",
                "yuva420p",
                "-auto-alt-ref",
                "0",
                "-crf",
                "30",
                "-b:v",
                "0",
            ]
        elif output_ext in [".mov"]:
            video_codec = "qtrle"  # QuickTime Animation (supports alpha)
            if has_alpha:
                codec_args = ["-c:v", video_codec, "-pix_fmt", "yuva420p"]
            else:
                codec_args = ["-c:v", video_codec]
        else:
            # Default to H.264 for .mp4 and others
            video_codec = "libx264"
            codec_args = ["-c:v", video_codec, "-preset", "medium", "-crf", "23"]

        # Build FFmpeg command
        cmd = ["ffmpeg", "-y", "-i", str(input_path)]

        if original_fps >= to:
            # No interpolation needed, just adjust framerate
            cmd.extend(["-r", str(to)])
        else:
            # Try minterpolate first
            test_cmd = ["ffmpeg", "-filters", "|", "grep", "minterpolate"]
            test_result = subprocess.run(
                " ".join(test_cmd), shell=True, capture_output=True, text=True
            )

            if "minterpolate" in test_result.stdout:
                # Use minterpolate for frame interpolation
                filter_str = f"minterpolate=fps={to}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"
                if has_alpha:
                    filter_str += ",format=yuva420p"
                cmd.extend(["-vf", filter_str])
            else:
                # Fallback: simple framerate conversion
                filter_str = f"fps={to}"
                if has_alpha:
                    filter_str += ",format=yuva420p"
                cmd.extend(["-vf", filter_str])

        # Always add codec arguments after filters
        cmd.extend(codec_args)

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
