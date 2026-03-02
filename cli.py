#!/usr/bin/env python3
"""
CLI tool for removing backgrounds from videos with alpha channel support.

Supports MOV and WebM output formats with transparency.
Uses OpenCV for processing and FFmpeg for final encoding.
"""

import cv2
import numpy as np
import subprocess
import shutil
import tempfile
import re
from pathlib import Path
from typing import Dict, Any


from bgremover import (
    generate_color_ranges,
    detect_background_color_from_video,
    detect_background_color_from_frame_border,
    detect_motion_region,
    create_motion_based_mask,
    fill_mask_holes,
    fill_enclosed_background,
)


def parse_color(color_str: str) -> list | None:
    """Parse color string - supports BGR (B,G,R), hex (#RRGGBB or RRGGBB)."""
    if color_str is None:
        return None

    color_str = color_str.strip()

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
    except ValueError:
        pass

    raise ValueError(
        f"Invalid color format: '{color_str}'. Use 'B,G,R', '#RRGGBB', or 'RRGGBB'"
    )


def get_output_format(output_path: str, format_flag: str | None) -> str:
    """
    Determine output format from path extension or flag.

    Args:
        output_path: Output file path
        format_flag: Optional format flag ('mov' or 'webm')

    Returns:
        'mov' or 'webm'
    """
    if format_flag is not None:
        return format_flag.lower()

    ext = Path(output_path).suffix.lower()
    if ext == ".webm":
        return "webm"
    return "mov"


def _encode_mov(frames_dir: Path, fps: float, output_path: str) -> str:
    """Encode PNG sequence to MOV with alpha using qtrle codec."""
    output_file = Path(output_path)
    final_output = output_file.parent / f"{output_file.stem}.mov"

    cmd = [
        "ffmpeg",
        "-y",
        "-framerate",
        str(fps),
        "-i",
        str(frames_dir / "frame_%05d.png"),
        "-c:v",
        "qtrle",
        str(final_output),
    ]

    subprocess.run(cmd, capture_output=True, check=True)
    return str(final_output)


def _encode_webm(frames_dir: Path, fps: float, output_path: str) -> str:
    """Encode PNG sequence to WebM with alpha using VP9 codec."""
    output_file = Path(output_path)
    final_output = output_file.parent / f"{output_file.stem}.webm"

    cmd = [
        "ffmpeg",
        "-y",
        "-framerate",
        str(fps),
        "-i",
        str(frames_dir / "frame_%05d.png"),
        "-c:v",
        "libvpx-vp9",
        "-pix_fmt",
        "yuva420p",
        "-auto-alt-ref",
        "0",
        "-crf",
        "30",
        "-b:v",
        "0",
        str(final_output),
    ]

    subprocess.run(cmd, capture_output=True, check=True)
    return str(final_output)


def _apply_soft_edges_alpha(mask: np.ndarray, soft_edges: int) -> np.ndarray:
    """Apply soft edges to a binary mask."""
    if mask is None or mask.sum() == 0:
        return mask

    if soft_edges <= 0:
        return mask

    kernel_size = 2 * soft_edges + 1
    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = np.ones((kernel_size, kernel_size), np.uint8)

    dilated = cv2.dilate(mask.astype(np.uint8), kernel, iterations=1)
    gradient = dilated - mask

    soft_mask = mask.astype(np.float32) / 255.0
    transition = gradient.astype(np.float32) / 255.0
    soft_mask = soft_mask + (transition * 0.5)

    return (soft_mask * 255).astype(np.uint8)


def _apply_edge_cleanup(mask: np.ndarray, edge_cleanup: int) -> np.ndarray:
    """Apply erosion to remove color spill from edges."""
    if edge_cleanup <= 0:
        return mask
    if mask is None or mask.sum() == 0:
        return mask
    kernel_size = 2 * edge_cleanup + 1
    kernel = np.ones((kernel_size, kernel_size), np.uint8)
    return cv2.erode(mask, kernel, iterations=1)


def _process_frame(
    frame: np.ndarray,
    color_ranges: list,
    soft_edges: int,
    edge_cleanup: int,
    use_adaptive_bg: bool = False,
    hole_fill_threshold: int = 15,
    flood_fill: bool = False,
) -> np.ndarray:
    """Process single frame to create alpha channel using multiple color ranges."""

    # If adaptive mode, detect background from frame borders
    if use_adaptive_bg:
        bg_color = detect_background_color_from_frame_border(frame, border_width=10)
        color_ranges = [{"color": bg_color, "tolerance": 30}]

    # Start with empty mask
    combined_mask = np.zeros(frame.shape[:2], dtype=np.uint8)

    # Process each color range and combine with OR
    for color_range in color_ranges:
        bg_b, bg_g, bg_r = color_range["color"]
        tolerance = color_range["tolerance"]

        # Calculate threshold bounds
        lower = np.array(
            [
                max(0, bg_b - tolerance),
                max(0, bg_g - tolerance),
                max(0, bg_r - tolerance),
            ],
            dtype=np.uint8,
        )
        upper = np.array(
            [
                min(255, bg_b + tolerance),
                min(255, bg_g + tolerance),
                min(255, bg_r + tolerance),
            ],
            dtype=np.uint8,
        )

        # Create mask for this color range
        range_mask = cv2.inRange(frame, lower, upper)

        # Combine with existing mask using OR
        combined_mask = cv2.bitwise_or(combined_mask, range_mask)

    # Invert to get foreground mask
    foreground_mask = cv2.bitwise_not(combined_mask)

    # Fill small holes in the mask
    if hole_fill_threshold > 0:
        foreground_mask = fill_mask_holes(foreground_mask, hole_fill_threshold)

    # Fill internal holes trapped between foreground pixels using contour-based fill
    if flood_fill:
        foreground_mask = fill_enclosed_background(foreground_mask, min_area=30)

    # Apply edge cleanup
    foreground_mask = _apply_edge_cleanup(foreground_mask, edge_cleanup)

    # Apply soft edges
    foreground_mask = _apply_soft_edges_alpha(foreground_mask, soft_edges)

    return foreground_mask


def remove_background(
    input_path: str,
    output_path: str,
    background_color: list,
    tolerance: int = 30,
    soft_edges: int = 5,
    show_progress: bool = False,
    auto_ranges: bool = True,
    num_ranges: int = 5,
    method: str = "color",
    motion_frames: int = 30,
    motion_threshold: int = 15,
    edge_cleanup: int = 3,
    adaptive_bg: bool = False,
    hole_fill: int = 25,
    flood_fill: bool = False,
) -> Dict[str, Any]:
    """
    Remove background from video and output with alpha channel.

    Since OpenCV's VideoWriter doesn't support 4-channel output natively,
    this function uses a workaround:
    1. Process frames and save as PNG sequence (with alpha)
    2. Use FFmpeg to combine PNG sequence into MOV/WebM with alpha

    Args:
        input_path: Input video path
        output_path: Output video path
        background_color: BGR color [B, G, R]
        tolerance: Color tolerance (default: 30)
        soft_edges: Soft edge size (default: 5)
        show_progress: Show progress (default: False)
        auto_ranges: Auto-generate color ranges (default: True)
        num_ranges: Number of auto-generated ranges (default: 5)
        method: Detection method - 'color', 'motion', or 'combined' (default: 'color')
        motion_frames: Number of frames to analyze for motion detection (default: 30)
        motion_threshold: Pixel difference threshold for motion (default: 15)
        edge_cleanup: Pixels to erode from foreground edges to remove color spill (default: 3)
        adaptive_bg: Detect background color per-frame from borders (default: False)
        hole_fill: Fill holes in mask smaller than this size (default: 25, 0 to disable)
        flood_fill: Fill internal holes trapped between foreground pixels (default: False)

    Returns:
        dict with success, output_path, error
    """
    result: Dict[str, Any] = {"success": False, "output_path": None, "error": None}

    temp_dir = None

    try:
        input_file = Path(input_path)
        if not input_file.exists():
            result["error"] = f"Input file not found: {input_path}"
            return result

        if shutil.which("ffmpeg") is None:
            result["error"] = (
                "FFmpeg not found. Please install FFmpeg for alpha channel support."
            )
            return result

        temp_dir = Path(tempfile.mkdtemp())

        cap = cv2.VideoCapture(input_path)
        if not cap.isOpened():
            result["error"] = f"Could not open video: {input_path}"
            return result

        fps = cap.get(cv2.CAP_PROP_FPS)
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

        # Generate color ranges if auto_ranges is enabled
        if auto_ranges:
            color_ranges = generate_color_ranges(
                background_color, num_ranges, tolerance
            )
            if show_progress:
                print(
                    f"Auto-generating {len(color_ranges)} color ranges from base color {background_color}"
                )
        else:
            color_ranges = [{"color": background_color, "tolerance": tolerance}]

        motion_mask = None
        if method in ("motion", "combined"):
            if show_progress:
                print("Detecting motion region...")
            motion_mask = detect_motion_region(
                input_path,
                num_frames=motion_frames,
                threshold=motion_threshold,
                dilate_kernel=11,
            )
            if show_progress:
                motion_pixels = np.count_nonzero(motion_mask) / motion_mask.size * 100
                print(f"Motion region: {motion_pixels:.1f}% of frame")

        frame_count = 0

        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # Create alpha mask based on detection method
            if method == "color":
                alpha = _process_frame(
                    frame,
                    color_ranges,
                    soft_edges,
                    edge_cleanup,
                    use_adaptive_bg=adaptive_bg,
                    hole_fill_threshold=hole_fill,
                    flood_fill=flood_fill,
                )
            elif method == "motion" and motion_mask is not None:
                alpha = create_motion_based_mask(
                    frame, motion_mask, background_color, tolerance
                )
            elif method == "combined" and motion_mask is not None:
                color_alpha = _process_frame(
                    frame,
                    color_ranges,
                    soft_edges,
                    edge_cleanup,
                    use_adaptive_bg=adaptive_bg,
                    hole_fill_threshold=hole_fill,
                    flood_fill=flood_fill,
                )
                motion_alpha = create_motion_based_mask(
                    frame, motion_mask, background_color, tolerance
                )
                alpha = cv2.bitwise_or(color_alpha, motion_alpha)
            else:
                # Fallback for combined method without motion mask
                alpha = _process_frame(
                    frame,
                    color_ranges,
                    soft_edges,
                    edge_cleanup,
                    use_adaptive_bg=adaptive_bg,
                    hole_fill_threshold=hole_fill,
                    flood_fill=flood_fill,
                )

            # Split frame channels
            b, g, r = cv2.split(frame)

            # Merge to BGRA
            bgra = cv2.merge([b, g, r, alpha])

            # Save as PNG
            frame_path = temp_dir / f"frame_{frame_count:05d}.png"
            cv2.imwrite(str(frame_path), bgra)

            frame_count += 1

            if show_progress and frame_count % 10 == 0:
                progress = (frame_count / total_frames) * 100
                print(f"\rProcessing: {progress:.1f}%", end="")

        cap.release()

        if show_progress:
            print(f"\rProcessing: 100%")

        # Determine output format
        output_format = get_output_format(output_path, None)

        # Encode to selected format
        if output_format == "webm":
            final_output = _encode_webm(temp_dir, fps, output_path)
            format_note = "WebM with VP9 alpha support"
        else:
            final_output = _encode_mov(temp_dir, fps, output_path)
            format_note = " MOV with QuickTime animation codec (alpha)"

        result["success"] = True
        result["output_path"] = str(final_output)

        if show_progress:
            print(f"\n✅ Success! Output: {final_output}")
            print(f"Note: {format_note}")

        return result

    except subprocess.CalledProcessError as e:
        result["error"] = f"FFmpeg error: {e.stderr.decode() if e.stderr else str(e)}"
    except Exception as e:
        result["error"] = str(e)
    finally:
        if temp_dir is not None and temp_dir.exists():
            try:
                shutil.rmtree(temp_dir, ignore_errors=True)
            except:
                pass

    return result


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Remove background with alpha channel")
    parser.add_argument("input", help="Input video")
    parser.add_argument("output", help="Output video")
    parser.add_argument(
        "-c",
        "--color",
        default=None,
        help="Background color (BGR: '0,255,0', hex: '#00FF00' or '00FF00'). Auto-detects if omitted.",
    )
    parser.add_argument("-t", "--tolerance", type=int, default=30)
    parser.add_argument("-e", "--edges", type=int, default=5)
    parser.add_argument("-p", "--progress", action="store_true")
    parser.add_argument(
        "--auto-ranges",
        action="store_true",
        dest="auto_ranges",
        default=True,
        help="Auto-generate color ranges (default)",
    )
    parser.add_argument(
        "--no-auto-ranges",
        action="store_false",
        dest="auto_ranges",
        help="Disable auto color ranges",
    )
    parser.add_argument(
        "-n",
        "--num-ranges",
        type=int,
        default=5,
        help="Number of auto-generated color ranges",
    )
    parser.add_argument(
        "-m",
        "--method",
        choices=["color", "motion", "combined"],
        default="color",
        help="Detection method: color (default), motion, combined",
    )
    parser.add_argument(
        "--motion-frames",
        type=int,
        default=30,
        help="Number of frames to analyze for motion detection (default: 30)",
    )
    parser.add_argument(
        "--edge-cleanup",
        type=int,
        default=3,
        help="Pixels to erode from edges to remove color spill (default: 3)",
    )
    parser.add_argument(
        "--adaptive-bg",
        action="store_true",
        default=False,
        help="Detect background per-frame from borders (better for varying lighting)",
    )
    parser.add_argument(
        "--hole-fill",
        type=int,
        default=25,
        help="Fill holes in mask smaller than this size (0 to disable, default: 25)",
    )
    parser.add_argument(
        "--flood-fill",
        action="store_true",
        default=False,
        help="Fill internal holes trapped between foreground pixels",
    )

    args = parser.parse_args()

    bg_color: list | None = None
    if args.color is not None:
        bg_color = parse_color(args.color)
    else:
        print("Auto-detecting background color from video borders...")
        detected_colors = detect_background_color_from_video(
            args.input, tolerance=args.tolerance
        )
        print(f"Detected colors: {detected_colors}")
        if not detected_colors:
            print("Could not detect background color. Using default.")
            bg_color = [115, 188, 129]
        else:
            bg_color = detected_colors[0]
            if len(detected_colors) > 1:
                print(f"Multiple colors detected, using primary: {bg_color}")

    # Enable flood_fill by default when using adaptive_bg
    flood_fill_enabled = args.flood_fill or args.adaptive_bg

    result = remove_background(
        input_path=args.input,
        output_path=args.output,
        background_color=bg_color,  # type: ignore
        tolerance=args.tolerance,
        soft_edges=args.edges,
        show_progress=args.progress,
        auto_ranges=args.auto_ranges,
        num_ranges=args.num_ranges,
        method=args.method,
        motion_frames=args.motion_frames,
        edge_cleanup=args.edge_cleanup,
        adaptive_bg=args.adaptive_bg,
        hole_fill=args.hole_fill,
        flood_fill=flood_fill_enabled,
    )

    if result["success"]:
        print(f"\n✅ Success! Output: {result['output_path']}")
    else:
        print(f"\n❌ Error: {result['error']}")
        exit(1)
