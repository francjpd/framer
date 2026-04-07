"""
Core library for background removal from videos.

Provides color-based and motion-based segmentation, mask refinement,
and video processing utilities with alpha channel support.
"""

import cv2
import numpy as np
import subprocess
import shutil
import tempfile
import re
from pathlib import Path
from typing import Dict, Any

from core.video import get_output_format
from core.parallel import process_video_parallel
from core.gpu import is_available
from core import gpu_ops

from core.color_ranges import (
    generate_color_ranges,
    detect_background_color_from_video,
    detect_background_color_from_frame_border,
)
from core.mask_refinement import (
    _apply_soft_edges,
    _apply_edge_cleanup,
    refine_frame,
)
from core.motion_detection import (
    detect_motion_region,
    create_motion_based_mask,
)





class VideoBackgroundRemover:
    """Remove background from videos using color-based segmentation."""

    def __init__(self, color_space="hsv"):
        """
        Initialize the background remover.

        Args:
            color_space: 'hsv' or 'bgr' - color space for segmentation
        """
        self.color_space = color_space
        self.color_ranges = []
        self.default_soft_edges = 5

    def add_color_range(
        self, target_color, tolerance=30, soft_edges=5, min_saturation=50, min_value=50
    ):
        """
        Add a color range to remove.

        Args:
            target_color: BGR color array [B, G, R] or [H, S, V] depending on color space
            tolerance: Color tolerance for segmentation (higher = more lenient)
            soft_edges: Number of pixels for soft edge transition (0 = hard edge)
            min_saturation: Minimum saturation (0-255) - for HSV only
            min_value: Minimum value/brightness (0-255) - for HSV only
        """
        if self.color_space == "hsv":
            # Convert target BGR to HSV for HSV-based removal
            target_hsv = cv2.cvtColor(np.uint8([[target_color]]), cv2.COLOR_BGR2HSV)[0][
                0
            ]
            self.color_ranges.append(
                {
                    "target": target_hsv,
                    "tolerance": tolerance,
                    "soft_edges": soft_edges,
                    "min_sat": min_saturation,
                    "min_val": min_value,
                }
            )
        else:
            self.color_ranges.append(
                {
                    "target": target_color,
                    "tolerance": tolerance,
                    "soft_edges": soft_edges,
                }
            )

    def detect_and_add_background_color(self, video_path, tolerance=25):
        """
        Auto-detect background color from video borders and add to removal ranges.

        Samples corners from frame 0, frame 1, and last frame.
        Adds all detected colors to the removal ranges.

        Args:
            video_path: Path to input video file
            tolerance: Color matching tolerance for detection (default: 25)
        """
        colors = detect_background_color_from_video(video_path, tolerance=tolerance)
        for color in colors:
            self.add_color_range(target_color=color, tolerance=tolerance)

    def _create_hsv_mask(self, frame):
        """Create mask for HSV color space."""
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        h, s, v = cv2.split(hsv)

        # Start with empty mask
        mask = np.zeros(h.shape, dtype=np.uint8)

        for color_range in self.color_ranges:
            target_h = color_range["target"][0]
            tolerance = color_range["tolerance"]

            # Calculate hue range
            hue_low = max(0, target_h - tolerance)
            hue_high = min(180, target_h + tolerance)

            # Create hue mask
            if hue_low <= hue_high:
                hue_mask = cv2.inRange(
                    h,
                    np.array([hue_low], dtype=np.uint8),
                    np.array([hue_high], dtype=np.uint8),
                )
            else:
                # Handle wrap-around (e.g., red at 0-10 and 170-180)
                hue_mask1 = cv2.inRange(
                    h,
                    np.array([hue_low], dtype=np.uint8),
                    np.array([180], dtype=np.uint8),
                )
                hue_mask2 = cv2.inRange(
                    h,
                    np.array([0], dtype=np.uint8),
                    np.array([hue_high], dtype=np.uint8),
                )
                hue_mask = cv2.bitwise_or(hue_mask1, hue_mask2)

            # Add saturation and value constraints
            sat_mask = cv2.inRange(
                s,
                np.array([color_range["min_sat"]], dtype=np.uint8),
                np.array([255], dtype=np.uint8),
            )
            val_mask = cv2.inRange(
                v,
                np.array([color_range["min_val"]], dtype=np.uint8),
                np.array([255], dtype=np.uint8),
            )

            # Combine all masks
            combined_mask = cv2.bitwise_and(hue_mask, sat_mask)
            combined_mask = cv2.bitwise_and(combined_mask, val_mask)

            # Combine with existing mask
            mask = cv2.bitwise_or(mask, combined_mask)

        return mask

    def _create_bgr_mask(self, frame):
        """Create mask for BGR color space."""
        mask = np.zeros(frame.shape[:2], dtype=np.uint8)

        for color_range in self.color_ranges:
            target_bgr = color_range["target"]
            tolerance = color_range["tolerance"]

            # Create mask for this color range
            lower_bound = np.array(
                [max(0, int(c - tolerance)) for c in target_bgr], dtype=np.uint8
            )
            upper_bound = np.array(
                [min(255, int(c + tolerance)) for c in target_bgr], dtype=np.uint8
            )

            range_mask = cv2.inRange(frame, lower_bound, upper_bound)
            mask = cv2.bitwise_or(mask, range_mask)

        return mask

    def _apply_soft_edges(self, mask, soft_edges=None):
        """Apply soft edges to mask using dilation and blending."""
        if soft_edges is None:
            soft_edges = self.default_soft_edges
        return _apply_soft_edges(mask, soft_edges)

    def process_frame(self, frame):
        """
        Process a single frame to remove background.

        Args:
            frame: Input BGR frame (numpy array)

        Returns:
            Frame with transparent background (BGRA format)
        """
        if self.color_space == "hsv":
            mask = self._create_hsv_mask(frame)
        else:
            mask = self._create_bgr_mask(frame)

        if mask is not None and mask.sum() > 0:
            # Use the soft_edges from the first color range as default
            soft_edges = (
                self.color_ranges[0]["soft_edges"]
                if self.color_ranges
                else self.default_soft_edges
            )
            mask = self._apply_soft_edges(mask, soft_edges)

        # Normalize mask to 0-1 range
        mask_normalized = mask.astype(np.float32) / 255.0

        # Split original frame
        b, g, r = cv2.split(frame)

        # Apply mask to create alpha channel (convert to uint8 for merge)
        alpha = (mask_normalized * 255).astype(np.uint8)

        # Merge back to BGRA
        result = cv2.merge([b, g, r, alpha])

        return result

    def process_video(self, input_path, output_path, show_progress=False):
        """
        Process entire video to remove background.

        Args:
            input_path: Path to input video file
            output_path: Path to output video file
            show_progress: Whether to display progress
        """
        # Open input video
        cap = cv2.VideoCapture(input_path)

        if not cap.isOpened():
            raise ValueError(f"Could not open input video: {input_path}")

        # Get video properties
        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

        # Define codec and create output video
        # Use PNG codec for MP4 to support alpha channel
        # Note: OpenCV VideoWriter doesn't support 4-channel output natively
        # For true alpha channel support, users should convert AVI to MP4 with alpha using FFmpeg
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        out = cv2.VideoWriter(output_path, fourcc, fps, (width, height), isColor=True)

        if not out.isOpened():
            raise ValueError(f"Could not create output video: {output_path}")

        frame_count = 0

        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # Process frame
            result = self.process_frame(frame)

            # Write frame (alpha channel will be handled by codec)
            out.write(result)

            frame_count += 1

            if show_progress:
                progress = (frame_count / total_frames) * 100
                from core.gpu import get_progress_string
                accel_str = get_progress_string()
                print(
                    f"\rProcessing{accel_str}: {progress:.1f}% ({frame_count}/{total_frames})",
                    end="",
                )

        cap.release()
        out.release()

        if show_progress:
            print(f"\nProcessing complete! Output saved to: {output_path}")

        return output_path





def _process_frame(
    frame: np.ndarray,
    color_ranges: list,
    soft_edges=None,
    edge_cleanup=None,
    use_adaptive_bg: bool = False,
) -> np.ndarray:
    """Process single frame to create alpha channel using multiple color ranges."""

    if use_adaptive_bg:
        bg_color = detect_background_color_from_frame_border(frame, border_width=10)
        color_ranges = [{"color": bg_color, "tolerance": 30}]

    combined_mask = np.zeros(frame.shape[:2], dtype=np.uint8)

    for color_range in color_ranges:
        bg_b, bg_g, bg_r = color_range["color"]
        tolerance = color_range["tolerance"]

        lower = np.array(
            [
                max(0, int(bg_b - tolerance)),
                max(0, int(bg_g - tolerance)),
                max(0, int(bg_r - tolerance)),
            ],
            dtype=np.uint8,
        )
        upper = np.array(
            [
                min(255, int(bg_b + tolerance)),
                min(255, int(bg_g + tolerance)),
                min(255, int(bg_r + tolerance)),
            ],
            dtype=np.uint8,
        )

        range_mask = cv2.inRange(frame, lower, upper)
        combined_mask = cv2.bitwise_or(combined_mask, range_mask)

    foreground_mask = cv2.bitwise_not(combined_mask)

    if edge_cleanup is not None:
        foreground_mask = _apply_edge_cleanup(foreground_mask, edge_cleanup)

    if soft_edges is not None:
        foreground_mask = _apply_soft_edges(foreground_mask, soft_edges)

    return foreground_mask


def _process_frame_gpu(
    frame: np.ndarray,
    color_ranges: list,
    soft_edges: int = None,
    edge_cleanup: int = None,
    use_adaptive_bg: bool = False,
) -> np.ndarray:
    """GPU-accelerated version of _process_frame."""
    if use_adaptive_bg:
        bg_color = detect_background_color_from_frame_border(frame, border_width=10)
        color_ranges = [{"color": bg_color, "tolerance": 30}]

    combined_mask = np.zeros(frame.shape[:2], dtype=np.uint8)

    for color_range in color_ranges:
        bg_b, bg_g, bg_r = color_range["color"]
        tolerance = color_range["tolerance"]

        lower = np.array(
            [
                max(0, int(bg_b - tolerance)),
                max(0, int(bg_g - tolerance)),
                max(0, int(bg_r - tolerance)),
            ],
            dtype=np.uint8,
        )
        upper = np.array(
            [
                min(255, int(bg_b + tolerance)),
                min(255, int(bg_g + tolerance)),
                min(255, int(bg_r + tolerance)),
            ],
            dtype=np.uint8,
        )

        range_mask = gpu_ops.in_range(frame, lower, upper)
        combined_mask = gpu_ops.bitwise_or(combined_mask, range_mask)

    foreground_mask = gpu_ops.bitwise_not(combined_mask)

    if edge_cleanup is not None and edge_cleanup > 0:
        foreground_mask = gpu_ops.erode(
            foreground_mask, edge_cleanup * 2 + 1, iterations=1
        )

    if soft_edges is not None and soft_edges > 0:
        blurred = gpu_ops.gaussian_blur(foreground_mask, soft_edges * 2 + 1)
        foreground_mask = gpu_ops.threshold(blurred, 127)

    return foreground_mask


def _remove_bg_frame_processor(frame: np.ndarray, **kwargs) -> np.ndarray:
    """Frame processor function for parallel background removal."""
    color_ranges = kwargs.get("color_ranges")
    method = kwargs.get("method", "color")
    motion_mask = kwargs.get("motion_mask")
    background_color = kwargs.get("background_color")
    tolerance = kwargs.get("tolerance", 30)
    refine = kwargs.get("refine", False)
    refine_tolerance = kwargs.get("refine_tolerance", 45)
    refine_block_size = kwargs.get("refine_block_size", 32)
    edge_cleanup = kwargs.get("edge_cleanup", 3)
    soft_edges = kwargs.get("soft_edges", 5)
    adaptive_bg = kwargs.get("adaptive_bg", False)
    use_gpu = kwargs.get("use_gpu", True)

    first_pass_edge_cleanup = None if refine else edge_cleanup
    first_pass_soft_edges = None if refine else soft_edges

    # Use GPU-accelerated processing if available
    if use_gpu and is_available() and not refine:
        if method == "color":
            alpha = _process_frame_gpu(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
        elif method == "motion" and motion_mask is not None:
            alpha = create_motion_based_mask(
                frame, motion_mask, background_color, tolerance
            )
        elif method == "combined" and motion_mask is not None:
            color_alpha = _process_frame_gpu(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
            motion_alpha = create_motion_based_mask(
                frame, motion_mask, background_color, tolerance
            )
            alpha = gpu_ops.bitwise_or(color_alpha, motion_alpha)
        else:
            alpha = _process_frame_gpu(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
    else:
        # CPU fallback
        if method == "color":
            alpha = _process_frame(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
        elif method == "motion" and motion_mask is not None:
            alpha = create_motion_based_mask(
                frame, motion_mask, background_color, tolerance
            )
        elif method == "combined" and motion_mask is not None:
            color_alpha = _process_frame(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
            motion_alpha = create_motion_based_mask(
                frame, motion_mask, background_color, tolerance
            )
            alpha = cv2.bitwise_or(color_alpha, motion_alpha)
        else:
            alpha = _process_frame(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )

    if refine:
        alpha = refine_frame(
            bgr_frame=frame,
            alpha=alpha,
            background_color=background_color,
            tolerance=refine_tolerance,
            block_size=refine_block_size,
            edge_cleanup=edge_cleanup,
            soft_edges=soft_edges,
        )

    b, g, r = cv2.split(frame)
    if frame.shape[2] == 4:
        # If input already has alpha, we might want to respect it or override it
        # Here we override it with our new alpha
        return cv2.merge([b, g, r, alpha])
    else:
        return cv2.merge([b, g, r, alpha])


def remove_background(
    input_path: str,
    output_path: str,
    background_color: list = None,
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
    refine: bool = False,
    refine_tolerance: int = 45,
    refine_block_size: int = 32,
    refine_interactive: bool = False,
    refine_save_previews: bool = False,
    workers: int = 1,
    use_gpu: bool = True,
) -> Dict[str, Any]:
    """
    Remove background from video and output with alpha channel using stream encoding.
    """
    result: Dict[str, Any] = {"success": False, "output_path": None, "error": None}

    try:
        input_file = Path(input_path)
        if not input_file.exists():
            result["error"] = f"Input file not found: {input_path}"
            return result

        if shutil.which("ffmpeg") is None:
            result["error"] = "FFmpeg not found. Please install FFmpeg."
            return result

        if background_color is None:
            detected = detect_background_color_from_video(
                input_path, tolerance=tolerance
            )
            background_color = detected[0] if detected else [115, 188, 129]

        cap = cv2.VideoCapture(input_path)
        if not cap.isOpened():
            result["error"] = f"Could not open video: {input_path}"
            return result

        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

        if auto_ranges:
            color_ranges = generate_color_ranges(
                background_color, num_ranges, tolerance
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

        if workers > 1:
            func_kwargs = {
                "color_ranges": color_ranges,
                "method": method,
                "motion_mask": motion_mask,
                "background_color": background_color,
                "tolerance": tolerance,
                "refine": refine,
                "refine_tolerance": refine_tolerance,
                "refine_block_size": refine_block_size,
                "edge_cleanup": edge_cleanup,
                "soft_edges": soft_edges,
                "adaptive_bg": adaptive_bg,
                "use_gpu": is_available(),
            }

            return process_video_parallel(
                input_path=input_path,
                output_path=output_path,
                process_func=_remove_bg_frame_processor,
                func_kwargs=func_kwargs,
                workers=workers,
                show_progress=show_progress,
            )

        else:
            from core.video import VideoStreamWriter

            with VideoStreamWriter(
                output_path=output_path,
                fps=fps,
                width=width,
                height=height,
                has_alpha=True,
            ) as writer:
                frame_count = 0
                while True:
                    ret, frame = cap.read()
                    if not ret:
                        break

                    first_pass_edge_cleanup = None if refine else edge_cleanup
                    first_pass_soft_edges = None if refine else soft_edges

                    if method == "color":
                        alpha = _process_frame(
                            frame,
                            color_ranges,
                            first_pass_soft_edges,
                            first_pass_edge_cleanup,
                            adaptive_bg,
                        )
                    elif method == "motion" and motion_mask is not None:
                        alpha = create_motion_based_mask(
                            frame, motion_mask, background_color, tolerance
                        )
                    elif method == "combined" and motion_mask is not None:
                        color_alpha = _process_frame(
                            frame,
                            color_ranges,
                            first_pass_soft_edges,
                            first_pass_edge_cleanup,
                            adaptive_bg,
                        )
                        motion_alpha = create_motion_based_mask(
                            frame, motion_mask, background_color, tolerance
                        )
                        alpha = cv2.bitwise_or(color_alpha, motion_alpha)
                    else:
                        alpha = _process_frame(
                            frame,
                            color_ranges,
                            first_pass_soft_edges,
                            first_pass_edge_cleanup,
                            adaptive_bg,
                        )

                    if refine:
                        alpha = refine_frame(
                            bgr_frame=frame,
                            alpha=alpha,
                            background_color=background_color,
                            tolerance=refine_tolerance,
                            block_size=refine_block_size,
                            edge_cleanup=edge_cleanup,
                            soft_edges=soft_edges,
                        )

                    b, g, r = cv2.split(frame)
                    bgra = cv2.merge([b, g, r, alpha])

                    writer.write_frame(bgra)

                    frame_count += 1
                    if show_progress and frame_count % 10 == 0:
                        from core.gpu import get_progress_string
                        accel_str = get_progress_string()
                        print(
                            f"\rProcessing{accel_str}: {(frame_count / total_frames) * 100:.1f}%",
                            end="",
                        )

            cap.release()
            if show_progress:
                print(f"\rProcessing: 100%")

            result["success"] = True
            result["output_path"] = output_path
            return result

    except subprocess.CalledProcessError as e:
        result["error"] = f"FFmpeg error: {e.stderr.decode() if e.stderr else str(e)}"
    except Exception as e:
        result["error"] = str(e)

    return result



