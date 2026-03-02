#!/usr/bin/env python3
"""
Helper module for AI agents to remove backgrounds from videos.
Provides a simple function interface that can be easily called by agents.

This module uses cli.py which outputs .mov files with alpha channel
for proper transparency support.
"""

import subprocess
import sys
import re
from pathlib import Path


def _parse_color(color_value):
    """
    Parse color from various formats:
    - BGR list/tuple: [B, G, R]
    - Hex string: '#RRGGBB' or 'RRGGBB'
    - BGR string: 'B,G,R'
    Returns BGR list or None if invalid.
    """
    if color_value is None:
        return None

    if isinstance(color_value, (list, tuple)):
        if len(color_value) == 3:
            return list(color_value)
        return None

    if isinstance(color_value, str):
        color_str = color_value.strip()
        if color_str.startswith("#"):
            color_str = color_str[1:]

        if re.match(r"^[0-9A-Fa-f]{6}$", color_str):
            r = int(color_str[0:2], 16)
            g = int(color_str[2:4], 16)
            b = int(color_str[4:6], 16)
            return [b, g, r]

        try:
            values = [int(x.strip()) for x in color_str.split(",")]
            if len(values) == 3:
                return values
        except:
            pass

    return None


def remove_video_background(
    input_path,
    output_path,
    background_color=None,
    tolerance=30,
    soft_edges=5,
    color_space="bgr",
    show_progress=False,
    auto_ranges=True,
    num_ranges=5,
    auto_detect=True,
    output_format=None,
):
    """
    Remove background from a video file with alpha channel (transparency).

    This function uses cli.py which outputs .mov or .webm files with
    alpha channel support.

    Args:
        input_path: Path to input video file
        output_path: Path to output video file. Format auto-detected from extension
                    (.webm -> WebM, .mov -> MOV), or use output_format parameter.
        background_color: BGR color to remove as list [B, G, R], hex string '#RRGGBB',
                         or None for auto-detect from video borders.
                         If None, auto-detects from video.
        tolerance: Color tolerance for segmentation (0-100, default: 30)
        soft_edges: Soft edge transition size (0 = hard edge, default: 5)
        color_space: 'hsv' or 'bgr' for segmentation (default: 'bgr')
        show_progress: Whether to show progress (default: False)
        auto_ranges: Auto-generate color ranges from base color (default: True)
        num_ranges: Number of auto-generated color ranges (default: 5)
        auto_detect: Auto-detect background color from video (default: True)
        output_format: Output format - 'mov' or 'webm'. Auto-detected from extension if not provided.

    Returns:
        dict with keys:
            - success: bool indicating success
            - output_path: path to output file if successful (.mov or .webm with alpha)
            - error: error message if failed

    Example:
        ```python
        # Auto-detect background from video
        result = remove_video_background(
            input_path="input.mp4",
            output_path="output.webm",
        )

        # Remove green background with transparency
        result = remove_video_background(
            input_path="input.mp4",
            output_path="output",  # Will become output.mov
            background_color=[0, 255, 0],  # Green
            tolerance=30
        )

        # Using hex color
        result = remove_video_background(
            input_path="input.mp4",
            output_path="output",
            background_color="#00FF00",
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

    # Determine output format from extension or parameter
    output_path_obj = Path(output_path)
    output_ext = output_path_obj.suffix.lower()

    if output_format is None:
        if output_ext == ".webm":
            output_format = "webm"
        else:
            output_format = "mov"

    # Handle output path - remove extension to add proper extension later
    output_base = str(output_path_obj.with_suffix(""))
    output_path_obj.parent.mkdir(parents=True, exist_ok=True)

    try:
        # Build command for alpha CLI tool (uses FFmpeg for alpha support)
        script_path = str(Path(__file__).parent / "cli.py")
        cmd = [
            sys.executable,
            script_path,
            str(input_path),
            output_base,
            "-t",
            str(tolerance),
            "-e",
            str(soft_edges),
        ]

        # Add format parameter
        if output_format:
            cmd.extend(["-f", output_format])

        # Add auto-ranges parameters
        if auto_ranges:
            cmd.extend(["--auto-ranges", "-n", str(num_ranges)])
        else:
            cmd.append("--no-auto-ranges")

        # Add color if specified (if not, CLI will auto-detect)
        if background_color is not None:
            parsed_color = _parse_color(background_color)
            if parsed_color is None:
                result["error"] = (
                    "background_color must be a list/tuple of 3 values [B, G, R], "
                    "or a hex string like '#RRGGBB'"
                )
                return result
            color_str = f"{parsed_color[0]},{parsed_color[1]},{parsed_color[2]}"
            cmd.extend(["-c", color_str])

        # Run the CLI tool
        if show_progress:
            print(f"Processing video: {input_path}")
            if background_color is not None:
                print(f"Target color: {background_color}")
            else:
                print("Target color: auto-detect")
            print(f"Running: {' '.join(cmd)}")

        process = subprocess.run(cmd, capture_output=True, text=True, check=False)

        if process.returncode == 0:
            # Output format is handled by CLI - it produces {base}.mov or {base}.webm
            if output_format == "webm":
                result["output_path"] = f"{output_base}.webm"
                format_note = "Output is .webm with alpha channel for transparency"
            else:
                result["output_path"] = f"{output_base}.mov"
                format_note = "Output is .mov with alpha channel for transparency"

            result["success"] = True

            if show_progress:
                print(f"✅ Background removed successfully!")
                print(f"Output saved to: {result['output_path']}")
                print(f"Note: {format_note}")
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
