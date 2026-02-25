import cv2
import numpy as np


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
                hue_mask = cv2.inRange(h, hue_low, hue_high)
            else:
                # Handle wrap-around (e.g., red at 0-10 and 170-180)
                hue_mask1 = cv2.inRange(h, hue_low, 180)
                hue_mask2 = cv2.inRange(h, 0, hue_high)
                hue_mask = cv2.bitwise_or(hue_mask1, hue_mask2)

            # Add saturation and value constraints
            sat_mask = cv2.inRange(s, color_range["min_sat"], 255)
            val_mask = cv2.inRange(v, color_range["min_val"], 255)

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
        if mask is None or mask.sum() == 0:
            return mask

        soft_mask = mask.astype(np.float32) / 255.0

        if soft_edges is None:
            soft_edges = self.default_soft_edges

        # Get kernel size based on soft_edges parameter
        kernel_size = 2 * soft_edges + 1 if soft_edges > 0 else 3

        if soft_edges > 0 and kernel_size > 1:
            # Create distance transform for soft edges
            if kernel_size % 2 == 0:
                kernel_size += 1

            kernel = np.ones((kernel_size, kernel_size), np.uint8)

            # Dilate the mask
            dilated = cv2.dilate(mask.astype(np.uint8), kernel, iterations=1)

            # Create gradient (transition zone)
            gradient = dilated - mask

            # Create soft transition
            soft_mask = mask.astype(np.float32) / 255.0
            transition = gradient.astype(np.float32) / 255.0
            soft_mask = soft_mask + (transition * 0.5)  # 50% opacity in transition zone

        return (soft_mask * 255).astype(np.uint8)

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
                print(
                    f"\rProcessing: {progress:.1f}% ({frame_count}/{total_frames})",
                    end="",
                )

        cap.release()
        out.release()

        if show_progress:
            print(f"\nProcessing complete! Output saved to: {output_path}")

        return output_path


def remove_background(
    input_path,
    output_path,
    background_color=[0, 255, 0],
    tolerance=30,
    soft_edges=5,
    color_space="hsv",
    show_progress=False,
):
    """
    Convenience function to remove background from a video.

    Args:
        input_path: Path to input video
        output_path: Path to output video
        background_color: Target BGR color to remove [B, G, R]
        tolerance: Color tolerance (higher = more lenient)
        soft_edges: Soft edge transition size (0 = hard edge)
        color_space: 'hsv' or 'bgr' for segmentation
        show_progress: Whether to show progress

    Returns:
        Output video path
    """
    remover = VideoBackgroundRemover(color_space=color_space)
    remover.add_color_range(
        target_color=background_color, tolerance=tolerance, soft_edges=soft_edges
    )

    return remover.process_video(
        input_path=input_path, output_path=output_path, show_progress=show_progress
    )
