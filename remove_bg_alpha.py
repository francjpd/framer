#!/usr/bin/env python3
"""
Script to process video with background removal and output with alpha channel.
Uses OpenCV for processing and FFmpeg for final encoding with alpha support.
"""

import cv2
import numpy as np
import subprocess
import shutil
import tempfile
from pathlib import Path
from typing import Dict, Any


def remove_background_with_alpha(
    input_path: str,
    output_path: str,
    background_color: list,
    tolerance: int = 30,
    soft_edges: int = 5,
    color_space: str = "bgr",
    show_progress: bool = False,
) -> Dict[str, Any]:
    """
    Remove background from video and output with alpha channel.

    Since OpenCV's VideoWriter doesn't support 4-channel output natively,
    this function uses a workaround:
    1. Process frames and save as PNG sequence (with alpha)
    2. Use FFmpeg to combine PNG sequence into MOV with alpha

    Args:
        input_path: Input video path
        output_path: Output video path (should be .mp4)
        background_color: BGR color [B, G, R]
        tolerance: Color tolerance (default: 30)
        soft_edges: Soft edge size (default: 5)
        color_space: 'hsv' or 'bgr' (default: 'bgr')
        show_progress: Show progress (default: False)

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

        # Check FFmpeg is available
        if shutil.which("ffmpeg") is None:
            result["error"] = (
                "FFmpeg not found. Please install FFmpeg for alpha channel support."
            )
            return result

        # Create temp directory for PNG sequence
        temp_dir = Path(tempfile.mkdtemp())

        # Open video
        cap = cv2.VideoCapture(input_path)
        if not cap.isOpened():
            result["error"] = f"Could not open video: {input_path}"
            return result

        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

        frame_count = 0

        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # Process frame
            alpha = _process_frame(
                frame, background_color, tolerance, soft_edges, color_space
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

        # Create MOV with qtrle codec which supports alpha
        output_file = Path(output_path)
        final_output = output_file.parent / f"{output_file.stem}-alpha.mov"

        ffmpeg_alpha_cmd = [
            "ffmpeg",
            "-y",
            "-framerate",
            str(fps),
            "-i",
            str(temp_dir / "frame_%05d.png"),
            "-c:v",
            "qtrle",
            str(final_output),
        ]

        subprocess.run(ffmpeg_alpha_cmd, capture_output=True, check=True)

        result["success"] = True
        result["output_path"] = str(final_output)

        if show_progress:
            print(f"✅ Background removed successfully!")
            print(f"Output saved to: {final_output}")
            print(
                "\nNote: MOV container with QuickTime animation codec supports alpha."
            )

        return result

    except subprocess.CalledProcessError as e:
        result["error"] = f"FFmpeg error: {e.stderr.decode() if e.stderr else str(e)}"
    except Exception as e:
        result["error"] = str(e)
    finally:
        # Clean up temp directory if exists
        try:
            if temp_dir is not None and temp_dir.exists():
                shutil.rmtree(temp_dir, ignore_errors=True)
        except:
            pass

    return result


def _process_frame(
    frame: np.ndarray,
    background_color: list,
    tolerance: int,
    soft_edges: int,
    color_space: str,
) -> np.ndarray:
    """Process single frame to create alpha channel."""
    bg_b, bg_g, bg_r = background_color

    # Calculate threshold bounds
    lower_b = max(0, bg_b - tolerance)
    upper_b = min(255, bg_b + tolerance)
    lower_g = max(0, bg_g - tolerance)
    upper_g = min(255, bg_g + tolerance)
    lower_r = max(0, bg_r - tolerance)
    upper_r = min(255, bg_r + tolerance)

    # Create masks for each channel
    mask_b = cv2.inRange(frame[:, :, 0], lower_b, upper_b)
    mask_g = cv2.inRange(frame[:, :, 1], lower_g, upper_g)
    mask_r = cv2.inRange(frame[:, :, 2], lower_r, upper_r)

    # Combine masks (background = all channels match)
    background_mask = cv2.bitwise_and(mask_b, mask_g)
    background_mask = cv2.bitwise_and(background_mask, mask_r)

    # Invert to get foreground mask
    foreground_mask = cv2.bitwise_not(background_mask)

    # Apply soft edges
    if soft_edges > 0:
        kernel_size = 2 * soft_edges + 1
        if kernel_size % 2 == 0:
            kernel_size += 1
        kernel = np.ones((kernel_size, kernel_size), np.uint8)

        # Dilate the mask
        dilated = cv2.dilate(foreground_mask.astype(np.uint8), kernel, iterations=1)

        # Create gradient (transition zone)
        gradient = dilated - foreground_mask

        # Create soft transition
        soft_mask = foreground_mask.astype(np.float32) / 255.0
        transition = gradient.astype(np.float32) / 255.0
        soft_mask = soft_mask + (transition * 0.5)

        return (soft_mask * 255).astype(np.uint8)

    return foreground_mask


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Remove background with alpha channel")
    parser.add_argument("input", help="Input video")
    parser.add_argument("output", help="Output video")
    parser.add_argument(
        "-c", "--color", default="115,188,129", help="Background BGR color"
    )
    parser.add_argument("-t", "--tolerance", type=int, default=35)
    parser.add_argument("-e", "--edges", type=int, default=5)
    parser.add_argument("-p", "--progress", action="store_true")

    args = parser.parse_args()

    bg_color = [int(x.strip()) for x in args.color.split(",")]

    result = remove_background_with_alpha(
        input_path=args.input,
        output_path=args.output,
        background_color=bg_color,
        tolerance=args.tolerance,
        soft_edges=args.edges,
        color_space="bgr",
        show_progress=args.progress,
    )

    if result["success"]:
        print(f"\n✅ Success! Output: {result['output_path']}")
    else:
        print(f"\n❌ Error: {result['error']}")
        exit(1)
