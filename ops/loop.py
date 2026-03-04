"""
Loop operation - creates seamless infinite video loops.
"""

import cv2
import numpy as np
import subprocess
import tempfile
import shutil
from pathlib import Path
from typing import Dict, Any, List, Tuple, Optional

from core import register_operation


def extract_frames(
    video_path: str, first_n: int = 20, last_n: int = 20
) -> Dict[str, List[np.ndarray]]:
    """Extract first N and last N frames from video."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS)

    all_frames = []
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        all_frames.append(frame)

    cap.release()

    first_frames = all_frames[:first_n]
    last_frames = all_frames[-last_n:] if len(all_frames) > last_n else all_frames

    return {
        "first": first_frames,
        "last": last_frames,
        "fps": fps,
        "total_frames": total_frames,
    }


def compute_frame_similarity(
    frame1: np.ndarray, frame2: np.ndarray, method: str = "mse"
) -> float:
    """
    Compute similarity between two frames.

    Returns: similarity score 0-100
    """
    if method == "optical_flow":
        gray1 = cv2.cvtColor(frame1, cv2.COLOR_BGR2GRAY)
        gray2 = cv2.cvtColor(frame2, cv2.COLOR_BGR2GRAY)

        flow = cv2.calcOpticalFlowFarneback(
            gray1, gray2, None, 0.5, 3, 15, 3, 5, 1.2, 0
        )

        magnitude = np.sqrt(flow[..., 0] ** 2 + flow[..., 1] ** 2)
        avg_motion = np.mean(magnitude)

        similarity = max(0, 100 - avg_motion)
        return similarity

    elif method == "mse":
        mse = np.mean((frame1.astype(float) - frame2.astype(float)) ** 2)
        similarity = max(0, 100 - mse / 10)
        return similarity

    else:
        raise ValueError(f"Unknown method: {method}")


def find_best_match_point(
    first_frames: List[np.ndarray], last_frames: List[np.ndarray], threshold: int = 85
) -> Tuple[Optional[int], Optional[int], float]:
    """
    Find best matching frame pair between first and last frames.

    Returns: (best_first_idx, best_last_idx, similarity_score)
    """
    if not first_frames or not last_frames:
        return (None, None, 0.0)

    best_score = 0
    best_first_idx = 0
    best_last_idx = 0

    for i, first_frame in enumerate(first_frames):
        for j, last_frame in enumerate(last_frames):
            score = compute_frame_similarity(first_frame, last_frame, method="mse")
            if score > best_score:
                best_score = score
                best_first_idx = i
                best_last_idx = j

    if best_score >= threshold:
        return (best_first_idx, best_last_idx, best_score)
    return (None, None, best_score)


def create_loop_cut(
    frames: List[np.ndarray], cut_first_idx: int, cut_last_idx: int
) -> List[np.ndarray]:
    """Create loop by cutting at match point."""
    loop_part = frames[cut_first_idx:]
    return loop_part


def create_loop_crossfade(
    frames: List[np.ndarray], first_n: int = 5, last_n: int = 5
) -> List[np.ndarray]:
    """Create smooth loop by crossfading between end and start."""
    if len(frames) < first_n + last_n:
        return frames

    blended = []

    for i in range(min(first_n, last_n)):
        last_frame = frames[-(last_n - i)]
        first_frame = frames[i]

        alpha = (i + 1) / (first_n + 1)
        blended_frame = cv2.addWeighted(last_frame, alpha, first_frame, 1 - alpha, 0)
        blended.append(blended_frame)

    result = frames[:first_n] + blended + frames[last_n:]
    return result


def create_loop_stretch(frames: List[np.ndarray]) -> List[np.ndarray]:
    """Time-stretch frames to make loop seamless (placeholder)."""
    return frames


def encode_video(frames: List[np.ndarray], output_path: str, fps: float) -> str:
    """Encode frames to video using FFmpeg."""
    if not frames:
        raise ValueError("No frames to encode")

    h, w = frames[0].shape[:2]

    output_ext = Path(output_path).suffix.lower()
    is_webm = output_ext == ".webm"

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        for i, frame in enumerate(frames):
            cv2.imwrite(str(temp_path / f"frame_{i:05d}.png"), frame)

        if is_webm:
            cmd = [
                "ffmpeg",
                "-y",
                "-framerate",
                str(fps),
                "-i",
                str(temp_path / "frame_%05d.png"),
                "-c:v",
                "libvpx-vp9",
                "-crf",
                "30",
                "-b:v",
                "0",
                output_path,
            ]
        else:
            cmd = [
                "ffmpeg",
                "-y",
                "-framerate",
                str(fps),
                "-i",
                str(temp_path / "frame_%05d.png"),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-crf",
                "23",
                output_path,
            ]

        subprocess.run(cmd, capture_output=True, check=True)

    return output_path


def create_loop(
    input_path: str,
    output_path: str,
    method: str = "auto",
    first_frames: int = 20,
    last_frames: int = 20,
    match_threshold: int = 85,
    show_matches: bool = False,
) -> Dict[str, Any]:
    """
    Main entry point for loop operation.

    Creates seamless infinite loops by matching frames between beginning and end.
    """
    result: Dict[str, Any] = {"success": False, "output_path": None, "error": None}

    try:
        frames_data = extract_frames(input_path, first_frames, last_frames)
        first = frames_data["first"]
        last = frames_data["last"]
        fps = frames_data["fps"]

        if not first or not last:
            result["error"] = "Video too short for loop detection"
            return result

        first_idx, last_idx, score = find_best_match_point(first, last, match_threshold)

        if first_idx is None:
            result["error"] = (
                f"No match found (best: {score:.1f}%, threshold: {match_threshold}%)"
            )
            return result

        full_frames = first + last

        if method == "cut":
            looped = create_loop_cut(full_frames, first_idx, last_idx)
        elif method == "crossfade":
            looped = create_loop_crossfade(
                full_frames, first_idx + 1, len(last) - last_idx
            )
        elif method == "stretch":
            looped = create_loop_stretch(full_frames)
        else:
            if score >= 90:
                looped = create_loop_cut(full_frames, first_idx, last_idx)
            else:
                looped = create_loop_crossfade(
                    full_frames, first_idx + 1, len(last) - last_idx
                )

        encode_video(looped, output_path, fps)

        result["success"] = True
        result["output_path"] = output_path

    except Exception as e:
        result["error"] = str(e)

    return result


register_operation(
    "loop",
    create_loop,
    {
        "method": {
            "type": "string",
            "default": "auto",
            "description": "Loop method: cut, crossfade, stretch, or auto",
        },
        "first_frames": {
            "type": "int",
            "default": 20,
            "description": "Number of frames to scan at start",
        },
        "last_frames": {
            "type": "int",
            "default": 20,
            "description": "Number of frames to match at end",
        },
        "match_threshold": {
            "type": "int",
            "default": 85,
            "description": "Minimum similarity threshold (0-100)",
        },
        "show_matches": {
            "type": "bool",
            "default": False,
            "description": "Show matched frame pairs for preview",
        },
    },
    description="Create seamless infinite video loops",
)
