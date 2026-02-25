#!/usr/bin/env python3
"""
Helper module for AI agents to remove backgrounds from videos.
Provides a simple function interface that can be easily called by agents.

This module uses remove_bg_alpha.py which outputs .mov files with alpha channel
for proper transparency support.
"""

import subprocess
import sys
from pathlib import Path


def remove_video_background(
    input_path,
    output_path,
    background_color=None,
    tolerance=30,
    soft_edges=5,
    color_space="bgr",
    show_progress=False,
):
    """
    Remove background from a video file with alpha channel (transparency).

    This function uses remove_bg_alpha.py which outputs .mov files with
    QuickTime Animation (qtrle) codec for proper alpha channel support.

    Args:
        input_path: Path to input video file
        output_path: Path to output video file (extension will be changed to .mov)
        background_color: BGR color to remove as list [B, G, R].
                         If None, uses default green [0, 255, 0].
        tolerance: Color tolerance for segmentation (0-100, default: 30)
        soft_edges: Soft edge transition size (0 = hard edge, default: 5)
        color_space: 'hsv' or 'bgr' for segmentation (default: 'bgr')
        show_progress: Whether to show progress (default: False)

    Returns:
        dict with keys:
            - success: bool indicating success
            - output_path: path to output file if successful (.mov with alpha)
            - error: error message if failed

    Example:
        ```python
        # Remove green background with transparency
        result = remove_video_background(
            input_path="input.mp4",
            output_path="output",  # Will become output-alpha.mov
            background_color=[0, 255, 0],  # Green
            tolerance=30
        )

        if result["success"]:
            print(f"Output saved to: {result['output_path']}")
        else:
            print(f"Error: {result['error']}")
        ```
    """
    result = {"success": False, "output_path": None, "error": None}

    # Validate input file exists
    input_file = Path(input_path)
    if not input_file.exists():
        result["error"] = f"Input file not found: {input_path}"
        return result

    # Handle output path - remove extension to add .mov later
    output_file = Path(output_path)
    output_base = str(output_file.with_suffix(""))  # Remove any extension
    output_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        # Build command for alpha CLI tool (uses FFmpeg for alpha support)
        script_path = str(Path(__file__).parent / "remove_bg_alpha.py")
        cmd = [
            sys.executable,
            script_path,
            str(input_path),
            output_base,  # Will output as {base}-alpha.mov
            "-t",
            str(tolerance),
            "-e",
            str(soft_edges),
        ]

        # Add color if specified
        if background_color is not None:
            if (
                isinstance(background_color, (list, tuple))
                and len(background_color) == 3
            ):
                color_str = (
                    f"{background_color[0]},{background_color[1]},{background_color[2]}"
                )
                cmd.extend(["-c", color_str])
            else:
                result["error"] = (
                    "background_color must be a list/tuple of 3 values [B, G, R]"
                )
                return result
        else:
            # Default to green
            cmd.extend(["-c", "0,255,0"])

        # Run the CLI tool
        if show_progress:
            print(f"Processing video: {input_path}")
            print(f"Target color: {background_color or [0, 255, 0]}")
            print(f"Running: {' '.join(cmd)}")

        process = subprocess.run(cmd, capture_output=True, text=True, check=False)

        if process.returncode == 0:
            # Output will be {base}-alpha.mov
            result["output_path"] = f"{output_base}-alpha.mov"
            result["success"] = True

            if show_progress:
                print(f"✅ Background removed successfully!")
                print(f"Output saved to: {result['output_path']}")
                print("Note: Output is .mov with alpha channel for transparency")
        else:
            result["error"] = (
                process.stderr.strip()
                or f"CLI tool exited with code {process.returncode}"
            )

            if show_progress:
                print(f"❌ Error: {result['error']}")

    except Exception as e:
        result["error"] = str(e)

        if show_progress:
            print(f"❌ Error: {result['error']}")

    return result


def remove_video_background_multi_color(
    input_path,
    output_path,
    color_ranges,
    tolerance=30,
    soft_edges=5,
    color_space="hsv",
    show_progress=False,
):
    """
    Remove background from a video using multiple color ranges.

    This is useful for videos where the background color varies slightly
    (e.g., different lighting conditions).

    Args:
        input_path: Path to input video file
        output_path: Path to output video file
        color_ranges: List of color range dicts, each containing:
            - color: BGR color [B, G, R]
            - tolerance: Optional override tolerance for this color
            - soft_edges: Optional override soft_edges for this color
        tolerance: Default color tolerance (default: 30)
        soft_edges: Soft edge transition size (default: 5)
        color_space: 'hsv' or 'bgr' (default: 'hsv')
        show_progress: Whether to show progress (default: False)

    Returns:
        dict with keys: success, output_path, error

    Example:
        ```python
        result = remove_video_background_multi_color(
            input_path="input.mp4",
            output_path="output.mp4",
            color_ranges=[
                {"color": [0, 255, 0], "tolerance": 25},  # Main green
                {"color": [10, 250, 10], "tolerance": 30},  # Slightly different green
            ],
            soft_edges=5
        )
        ```
    """
    # For multi-color, we need to use the Python library directly
    # rather than the CLI (which only supports single color)
    try:
        from bgremover import VideoBackgroundRemover

        remover = VideoBackgroundRemover(color_space=color_space)

        for color_range in color_ranges:
            target_color = color_range["color"]
            range_tolerance = color_range.get("tolerance", tolerance)
            range_edges = color_range.get("soft_edges", soft_edges)

            remover.add_color_range(
                target_color=target_color,
                tolerance=range_tolerance,
                soft_edges=range_edges,
            )

        output_path = remover.process_video(
            input_path=input_path, output_path=output_path, show_progress=show_progress
        )

        return {"success": True, "output_path": output_path, "error": None}

    except ImportError:
        return {
            "success": False,
            "output_path": None,
            "error": "bgremover module not available. Install with: pip install -r requirements.txt",
        }
    except Exception as e:
        return {"success": False, "output_path": None, "error": str(e)}


# For compatibility with older code
process_video = remove_video_background
