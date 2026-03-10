import cv2
import numpy as np


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
