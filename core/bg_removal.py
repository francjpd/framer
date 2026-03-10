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


def generate_color_ranges(base_bgr_color, num_ranges=5, base_tolerance=25):
    """
    Generate multiple color ranges from a base color to capture variations.

    Args:
        base_bgr_color: Base color in BGR format [B, G, R]
        num_ranges: Number of variations to generate (default: 5)
        base_tolerance: Base tolerance for each range (default: 25)

    Returns:
        List of color range dicts: [{"color": [...], "tolerance": XX}, ...]
    """
    ranges = []
    b, g, r = base_bgr_color

    ranges.append({"color": [b, g, r], "tolerance": base_tolerance})

    variations = [
        ("lighter", 15),
        ("darker", 15),
        ("high_green", 20),
        ("low_green", 20),
        ("brighter", 25),
        ("darker_green", 25),
        ("slight_light", 10),
    ]

    for name, variation in variations[: num_ranges - 1]:
        new_b = max(0, min(255, b + variation))
        new_g = max(0, min(255, g + variation))
        new_r = max(0, min(255, r + variation))

        ranges.append({"color": [new_b, new_g, new_r], "tolerance": base_tolerance + 5})

    return ranges


def _color_distance(color1, color2):
    """Calculate Euclidean distance between two BGR colors."""
    return sum((c1 - c2) ** 2 for c1, c2 in zip(color1, color2)) ** 0.5


def _cluster_colors(colors, tolerance):
    """
    Cluster colors that are within tolerance of each other.

    Args:
        colors: List of BGR color tuples
        tolerance: Maximum distance to consider colors as matching

    Returns:
        List of unique representative colors
    """
    if not colors:
        return []

    clusters = []

    for color in colors:
        matched = False
        for cluster in clusters:
            representative = cluster[0]
            if _color_distance(color, representative) <= tolerance:
                cluster.append(color)
                matched = True
                break

        if not matched:
            clusters.append([color])

    representative_colors = []
    for cluster in clusters:
        avg_b = int(sum(c[0] for c in cluster) / len(cluster))
        avg_g = int(sum(c[1] for c in cluster) / len(cluster))
        avg_r = int(sum(c[2] for c in cluster) / len(cluster))
        representative_colors.append((avg_b, avg_g, avg_r))

    return representative_colors


def detect_background_color_from_video(
    video_path,
    corner_size=5,
    tolerance=25,
):
    """
    Detect background color from video border corners.

    Samples 5x5 corners from frame 0, frame 1, and last frame.
    If colors match within tolerance, returns single color.
    If colors differ, returns all unique colors for removal range.

    Args:
        video_path: Path to input video file
        corner_size: Size of corner patch to sample (default: 5)
        tolerance: Color matching tolerance (default: 25)

    Returns:
        List of unique BGR colors to remove
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total_frames < 1:
        cap.release()
        raise ValueError("Video has no frames")

    frame_indices = [0, 1, total_frames - 1]
    all_colors = []

    for frame_idx in frame_indices:
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_idx)
        ret, frame = cap.read()
        if not ret:
            continue

        h, w = frame.shape[:2]

        corners = [
            (0, 0),
            (w - corner_size, 0),
            (0, h - corner_size),
            (w - corner_size, h - corner_size),
        ]

        for cx, cy in corners:
            corner_patch = frame[cy : cy + corner_size, cx : cx + corner_size]
            avg_color = corner_patch.mean(axis=(0, 1))
            all_colors.append(tuple(int(c) for c in avg_color))

    cap.release()

    if not all_colors:
        raise ValueError("Could not sample any colors from video")

    unique_colors = _cluster_colors(all_colors, tolerance)

    return unique_colors


def detect_background_color_from_frame_border(frame, border_width=10):
    """
    Detect background color from frame border.

    Samples pixels from all four edges of the frame and returns
    the average color, which represents the background.

    Args:
        frame: BGR frame (numpy array)
        border_width: Number of pixels to sample from border (default: 10)

    Returns:
        List [B, G, R] representing average border color
    """
    h, w = frame.shape[:2]
    bw = min(border_width, h // 4, w // 4)

    top = frame[:bw, :]
    bottom = frame[-bw:, :]
    left = frame[:, :bw]
    right = frame[:, -bw:]

    border_pixels = np.concatenate(
        [
            top.reshape(-1, 3),
            bottom.reshape(-1, 3),
            left.reshape(-1, 3),
            right.reshape(-1, 3),
        ]
    )

    avg_color = border_pixels.mean(axis=0)
    return [int(avg_color[0]), int(avg_color[1]), int(avg_color[2])]


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


def _apply_soft_edges(mask: np.ndarray, soft_edges: int) -> np.ndarray:
    """Apply soft edges to a binary mask."""
    if mask is None or mask.sum() == 0 or soft_edges <= 0:
        return mask

    kernel_size = 2 * soft_edges + 1
    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = np.ones((kernel_size, kernel_size), np.uint8)

    dilated = cv2.dilate(mask.astype(np.uint8), kernel, iterations=1)
    gradient = dilated - mask

    soft_mask = mask.astype(np.float32) / 255.0
    transition = gradient.astype(np.float32) / 255.0
    return (255 * (soft_mask + transition * 0.5)).astype(np.uint8)


def _apply_edge_cleanup(mask: np.ndarray, edge_cleanup: int) -> np.ndarray:
    """Apply erosion to remove color spill from edges."""
    if edge_cleanup <= 0 or mask is None or mask.sum() == 0:
        return mask
    kernel_size = 2 * edge_cleanup + 1
    kernel = np.ones((kernel_size, kernel_size), np.uint8)
    return cv2.erode(mask, kernel, iterations=1)


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


def _color_match_in_ranges(pixel, color_ranges):
    """Check if a pixel matches any of the background color ranges."""
    b, g, r = pixel
    for color_range in color_ranges:
        bg_b, bg_g, bg_r = color_range["color"]
        tolerance = color_range["tolerance"]
        if (
            abs(int(b) - bg_b) <= tolerance
            and abs(int(g) - bg_g) <= tolerance
            and abs(int(r) - bg_r) <= tolerance
        ):
            return True
    return False


def _detect_missed_background_pixel(
    foreground_pixels, color_ranges, tolerance_override=None
):
    """Detect pixels that match background color but weren't removed."""
    tolerance = tolerance_override if tolerance_override else 45
    missed = []
    for y, x, pixel in foreground_pixels:
        b, g, r = pixel
        for color_range in color_ranges:
            bg = color_range["color"]
            tol = tolerance_override if tolerance_override else color_range["tolerance"]
            if (
                abs(int(b) - bg[0]) <= tol
                and abs(int(g) - bg[1]) <= tol
                and abs(int(r) - bg[2]) <= tol
            ):
                missed.append((y, x))
                break
    return missed


def _detect_missed_background_blocks(
    frame, alpha_mask, color_ranges, block_size=32, tolerance_override=45
):
    """Detect blocks that have significant background color content."""
    h, w = frame.shape[:2]
    missed_blocks = []

    for by in range(0, h, block_size):
        for bx in range(0, w, block_size):
            block_y = slice(by, min(by + block_size, h))
            block_x = slice(bx, min(bx + block_size, w))

            block_alpha = alpha_mask[block_y, block_x]
            if block_alpha.sum() == 0:
                continue

            block_pixels = frame[block_y, block_x]
            fg_pixels = block_pixels[block_alpha > 0]

            if len(fg_pixels) == 0:
                continue

            bg_count = 0
            total_fg = len(fg_pixels)

            for pixel in fg_pixels:
                b, g, r = pixel
                for color_range in color_ranges:
                    bg = color_range["color"]
                    tol = (
                        tolerance_override
                        if tolerance_override
                        else color_range["tolerance"]
                    )
                    if (
                        abs(int(b) - bg[0]) <= tol
                        and abs(int(g) - bg[1]) <= tol
                        and abs(int(r) - bg[2]) <= tol
                    ):
                        bg_count += 1
                        break

            if bg_count > total_fg * 0.5:
                missed_blocks.append((by, bx, block_size, block_size))

    return missed_blocks


def _detect_missed_background_regions(
    frame, alpha_mask, color_ranges, tolerance_override=45
):
    """Detect connected regions that match background color."""
    h, w = frame.shape[:2]

    fg_mask = (alpha_mask > 0).astype(np.uint8)

    kernel = np.ones((5, 5), np.uint8)
    fg_mask = cv2.dilate(fg_mask, kernel, iterations=1)

    contours, _ = cv2.findContours(fg_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    missed_regions = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if area < 50:
            continue

        mask = np.zeros((h, w), np.uint8)
        cv2.drawContours(mask, [contour], -1, 255, -1)

        fg_pixels = frame[mask > 0]

        bg_count = 0
        total = len(fg_pixels)

        for pixel in fg_pixels:
            b, g, r = pixel
            for color_range in color_ranges:
                bg = color_range["color"]
                tol = (
                    tolerance_override
                    if tolerance_override
                    else color_range["tolerance"]
                )
                if (
                    abs(int(b) - bg[0]) <= tol
                    and abs(int(g) - bg[1]) <= tol
                    and abs(int(r) - bg[2]) <= tol
                ):
                    bg_count += 1
                    break

        if total > 0 and bg_count > total * 0.4:
            missed_regions.append(contour)

    return missed_regions


def refine_frame(
    bgr_frame: np.ndarray,
    alpha: np.ndarray,
    background_color: list,
    tolerance: int = 45,
    block_size: int = 32,
    edge_cleanup: int = None,
    soft_edges: int = None,
) -> np.ndarray:
    """
    Refine a single frame to catch missed background-colored pixels inline.
    Returns the refined alpha mask.
    """
    color_ranges = generate_color_ranges(
        background_color, num_ranges=3, base_tolerance=tolerance
    )

    original_alpha = alpha.copy()

    missed_pixels = []

    fg_positions = np.where(alpha > 0)
    foreground_pixels = list(
        zip(
            fg_positions[0],
            fg_positions[1],
            bgr_frame[fg_positions[0], fg_positions[1]],
        )
    )

    if foreground_pixels:
        missed_pixels = _detect_missed_background_pixel(
            foreground_pixels, color_ranges, tolerance
        )

    missed_blocks = _detect_missed_background_blocks(
        bgr_frame, alpha, color_ranges, block_size, tolerance
    )

    missed_regions = _detect_missed_background_regions(
        bgr_frame, alpha, color_ranges, tolerance
    )

    for y, x in missed_pixels:
        alpha[y, x] = 0

    for by, bx, bh, bw in missed_blocks:
        block_alpha = alpha[by : by + bh, bx : bx + bw]
        if block_alpha.sum() > 0:
            block_pixels = bgr_frame[by : by + bh, bx : bx + bw]
            for py in range(bh):
                for px in range(bw):
                    if block_alpha[py, px] > 0:
                        pixel = block_pixels[py, px]
                        for cr in color_ranges:
                            bg = cr["color"]
                            if (
                                abs(int(pixel[0]) - bg[0]) <= tolerance
                                and abs(int(pixel[1]) - bg[1]) <= tolerance
                                and abs(int(pixel[2]) - bg[2]) <= tolerance
                            ):
                                alpha[by + py, bx + px] = 0
                                break

    for contour in missed_regions:
        mask = np.zeros(alpha.shape, np.uint8)
        cv2.drawContours(mask, [contour], -1, 255, -1)
        alpha = cv2.bitwise_and(alpha, cv2.bitwise_not(mask))

    if edge_cleanup is not None:
        alpha = _apply_edge_cleanup(alpha, edge_cleanup)

    if soft_edges is not None:
        alpha = _apply_soft_edges(alpha, soft_edges)

    return alpha


def detect_motion_region(video_path, num_frames=30, threshold=15, dilate_kernel=11):
    """
    Detect moving subject using frame differencing.

    Args:
        video_path: Path to input video file
        num_frames: Number of frames to analyze for motion accumulation
        threshold: Pixel difference threshold for motion detection
        dilate_kernel: Kernel size for dilating motion mask (0 to disable)

    Returns:
        Binary mask where 255 = motion region, 0 = static
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")

    ret, prev_frame = cap.read()
    if not ret:
        cap.release()
        raise ValueError("Could not read first frame")

    prev_gray = cv2.cvtColor(prev_frame, cv2.COLOR_BGR2GRAY)
    motion_mask = np.zeros(prev_gray.shape, dtype=np.uint8)

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frames_to_check = min(num_frames, total_frames - 1)

    for i in range(frames_to_check):
        ret, frame = cap.read()
        if not ret:
            break

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        diff = cv2.absdiff(prev_gray, gray)
        _, thresh = cv2.threshold(diff, threshold, 255, cv2.THRESH_BINARY)
        motion_mask = cv2.bitwise_or(motion_mask, thresh)
        prev_gray = gray

    cap.release()

    if dilate_kernel > 0:
        kernel = np.ones((dilate_kernel, dilate_kernel), np.uint8)
        motion_mask = cv2.dilate(motion_mask, kernel, iterations=3)

    return motion_mask


def create_motion_based_mask(frame, motion_mask, bg_color, color_threshold=20):
    """
    Create refined mask using motion region + color difference.

    Args:
        frame: Input BGR frame
        motion_mask: Binary mask of motion region (255 = motion)
        bg_color: Background color in BGR [B, G, R]
        color_threshold: Color distance threshold for foreground

    Returns:
        Binary mask where 255 = foreground, 0 = background
    """
    bg = np.array(bg_color, dtype=np.float32)
    dist = np.sqrt(np.sum((frame.astype(np.float32) - bg) ** 2, axis=2))
    color_mask = (dist > color_threshold).astype(np.uint8) * 255

    refined = cv2.bitwise_and(color_mask, motion_mask)

    kernel = np.ones((5, 5), np.uint8)
    refined = cv2.dilate(refined, kernel, iterations=1)

    return refined
