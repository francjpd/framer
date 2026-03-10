import cv2
import numpy as np


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
