"""
Loop operation - creates seamless infinite video loops.
"""

from typing import Any

import cv2
import numpy as np

from core import register_operation
from core.utils import parse_color_rgba


def apply_blend_mode(frame1: np.ndarray, frame2: np.ndarray, mode: str) -> np.ndarray:
    """Apply blend mode between two frames."""
    f1 = frame1.astype(float)
    f2 = frame2.astype(float)

    if mode == "add":
        result = np.clip(f1 + f2, 0, 255).astype(np.uint8)
    elif mode == "multiply":
        result = (f1 * f2 / 255).astype(np.uint8)
    elif mode == "screen":
        result = 255 - (255 - f1) * (255 - f2) / 255
        result = np.clip(result, 0, 255).astype(np.uint8)
    elif mode == "overlay":
        result = np.where(
            f1 < 128, 2 * f1 * f2 / 255, 255 - 2 * (255 - f1) * (255 - f2) / 255
        )
        result = np.clip(result, 0, 255).astype(np.uint8)
    else:
        result = cv2.addWeighted(frame1, 0.5, frame2, 0.5, 0)

    return result


def detect_cycle_period(
    frames: list[np.ndarray], max_period: int = 120
) -> int | None:
    """Auto-detect periodic motion using frame differences.

    Returns: Detected cycle period in frames, or None if no clear cycle.
    """
    if len(frames) < 10:
        return None

    n = min(len(frames), max_period)
    diffs = []

    for i in range(1, n):
        diff = np.mean(np.abs(frames[i].astype(float) - frames[i - 1].astype(float)))
        diffs.append(diff)

    autocorr = np.correlate(diffs, diffs, mode="full")
    autocorr = autocorr[len(autocorr) // 2 :]

    peaks = []
    for i in range(2, len(autocorr) - 1):
        if (
            autocorr[i] > autocorr[i - 1]
            and autocorr[i] > autocorr[i + 1]
            and autocorr[i] > np.mean(autocorr) * 1.2
        ):
            peaks.append(i)

    if peaks:
        return peaks[0]
    return None


def extract_all_frames(
    video_path: str, show_progress: bool = False
) -> list[np.ndarray]:
    """Extract all frames from video."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frames = []
    frame_count = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frames.append(frame)
        frame_count += 1

        if show_progress:
            prog = (frame_count / total_frames) * 100 if total_frames > 0 else 0
            print(
                f"\rExtracting frames: {prog:.1f}% ({frame_count}/{total_frames})",
                end="",
            )

    cap.release()

    if show_progress:
        print()

    return frames


def create_pingpong_loop(frames: list[np.ndarray], fps: float = 30.0, until: float | None = None) -> list[np.ndarray]:
    """Create pingpong (boomerang) loop - forward then backward.

    Best for: bouncing objects, pendulum, breathing, any reversible motion.
    Plays video forward, then reverses, creating smooth yoyo effect.
    """
    if len(frames) < 2:
        return frames

    if until is not None:
        target_frame = int(until * fps)
        if target_frame < 0:
            target_frame = len(frames) + target_frame
            
        target_frame = max(0, min(target_frame, len(frames)))
        
        pre_loop = frames[:target_frame]
        loop_part = frames[target_frame:]
        
        if len(loop_part) < 2:
            return frames
            
        forward = loop_part[:]
        backward = loop_part[:-1][::-1]
        
        return pre_loop + forward + backward
    else:
        forward = frames[:]
        backward = frames[:-1][::-1]

        return forward + backward



def create_reverse_loop(frames: list[np.ndarray]) -> list[np.ndarray]:
    """Create reverse loop - forward then full reverse.

    Best for: reversible motion like water ripples, fire, particles,
    any motion that looks the same forwards and backwards.
    """
    if len(frames) < 2:
        return frames

    forward = frames[:]
    reverse = frames[::-1]

    return forward + reverse


def create_hold_loop(
    frames: list[np.ndarray], hold_frames: int = 2
) -> list[np.ndarray]:
    """Create hold loop - freeze briefly at transition point.

    Best for: videos with natural pauses or holds in the motion.
    Freezes the transition frame for a few frames to mask the seam.
    """
    if len(frames) < 4 or hold_frames < 1:
        return frames

    result = frames[:]

    for _ in range(hold_frames):
        result.append(frames[-1])

    return result


def create_fade_loop(
    frames: list[np.ndarray],
    fade_color: str = "transparent",
    fade_frames: int = 10,
    fade_type: str = "both",
) -> list[np.ndarray]:
    """Create fade loop - fade out/in at transition point.

    Best for: when nothing else works - masks seams completely with fade.
    Supports transparent (for alpha videos) or custom colors.
    """
    if len(frames) < fade_frames * 2:
        return frames

    color = parse_color_rgba(fade_color)
    fade_frames = min(fade_frames, len(frames) // 4)

    result = []
    n = len(frames)

    fade_frame = np.full(
        (frames[0].shape[0], frames[0].shape[1], 4), color, dtype=np.uint8
    )
    if len(frames[0].shape) == 3 and frames[0].shape[2] == 3:
        fade_frame = fade_frame[:, :, :3]

    for i in range(n):
        frame = frames[i].copy()

        if fade_type in ("out", "both"):
            fade_out_start = n - fade_frames * 2
            if i >= fade_out_start:
                alpha = (i - fade_out_start) / fade_frames
                alpha = min(1.0, alpha)
                frame = cv2.addWeighted(frame, 1 - alpha, fade_frame, alpha, 0)

        if fade_type in ("in", "both") and i < fade_frames * 2:
            alpha = 1 - (i / fade_frames)
            alpha = max(0, alpha)
            frame = cv2.addWeighted(frame, 1 - alpha, fade_frame, alpha, 0)

        result.append(frame)

    return result


def create_blend_loop(
    frames: list[np.ndarray], blend_mode: str = "add", blend_frames: int = 5
) -> list[np.ndarray]:
    """Create blend loop - creative blend between end and start.

    Best for: artistic effects, creative transitions.
    Uses blend modes: add, multiply, screen, overlay.
    """
    if len(frames) < blend_frames * 2:
        return frames

    result = frames[:-blend_frames]

    first_frames = frames[:blend_frames]
    last_frames = frames[-blend_frames:][::-1]

    for i in range(blend_frames):
        blended = apply_blend_mode(last_frames[i], first_frames[i], blend_mode)
        result.append(blended)

    result.extend(frames[blend_frames:])

    return result


def create_speedramp_loop(
    frames: list[np.ndarray], ramp_factor: float = 1.0
) -> list[np.ndarray]:
    """Create speedramp loop - adjust playback speed at transition.

    Best for: when loop points almost match but need slight speed adjustment.
    Slightly speeds up or slows down to make endpoints align.
    """
    if len(frames) < 4 or ramp_factor == 1.0:
        return frames

    ramp_factor = max(0.5, min(2.0, ramp_factor))

    result = frames[:]

    target_len = int(len(frames) * ramp_factor)
    if target_len != len(frames):
        indices = np.linspace(0, len(frames) - 1, target_len)
        result = [frames[int(i)] for i in indices]

    return result


def create_morph_loop(
    frames: list[np.ndarray], morph_steps: int = 10
) -> list[np.ndarray]:
    """Create morph loop - multiple warp steps between end and start.

    Best for: complex motion where simple interpolation fails.
    Uses optical flow to warp frames gradually from end to start.
    """
    if len(frames) < 10 or morph_steps <= 0:
        return frames

    end_frame = frames[-1]
    start_frame = frames[0]

    gray_end = cv2.cvtColor(end_frame, cv2.COLOR_BGR2GRAY)
    gray_start = cv2.cvtColor(start_frame, cv2.COLOR_BGR2GRAY)

    flow = cv2.calcOpticalFlowFarneback(
        gray_end, gray_start, None, 0.5, 3, 15, 3, 5, 1.2, 0
    )

    h, w = gray_end.shape
    morphed = []

    for i in range(1, morph_steps + 1):
        t = i / (morph_steps + 1)

        flow_map = flow * t
        x, y = np.meshgrid(np.arange(w), np.arange(h))
        map_x = (x + flow_map[..., 0]).astype(np.float32)
        map_y = (y + flow_map[..., 1]).astype(np.float32)

        warped = cv2.remap(end_frame, map_x, map_y, cv2.INTER_LINEAR)
        result = cv2.addWeighted(warped, 1 - t, start_frame, t, 0)
        morphed.append(result)

    return frames + morphed


def create_periodic_loop(
    frames: list[np.ndarray], cycle_frames: int | None = None
) -> list[np.ndarray]:
    """Create periodic loop - loop at natural cycle points.

    Best for: walking, running, waves - any rhythmic/repetitive motion.
    Auto-detects cycle period or uses specified cycle length.
    """
    if len(frames) < 10:
        return frames

    if cycle_frames is None:
        cycle_frames = detect_cycle_period(frames)

    if cycle_frames is None or cycle_frames >= len(frames):
        cycle_frames = len(frames) // 2

    cycle_frames = max(1, min(cycle_frames, len(frames) - 1))

    return frames[:cycle_frames]


def analyze_best_method(frames: list[np.ndarray]) -> dict[str, Any]:
    """Analyze video and recommend best loop method.

    Returns dict with:
    - recommended: best method name
    - alternatives: list of methods that could work
    - analysis: dict with motion metrics
    """
    if len(frames) < 10:
        return {"recommended": "hold", "alternatives": ["hold"], "analysis": {}}

    first_frame = frames[0]
    last_frame = frames[-1]

    diff_first_last = np.mean(
        np.abs(first_frame.astype(float) - last_frame.astype(float))
    )

    motion_scores = []
    for i in range(1, min(30, len(frames))):
        diff = np.mean(np.abs(frames[i].astype(float) - frames[i - 1].astype(float)))
        motion_scores.append(diff)

    avg_motion = np.mean(motion_scores) if motion_scores else 0

    cycle = detect_cycle_period(frames)

    analysis = {
        "frame_count": len(frames),
        "first_last_diff": float(diff_first_last),
        "avg_motion": float(avg_motion),
        "detected_cycle": cycle,
    }

    methods = []

    if cycle and cycle < len(frames) * 0.8:
        methods.append(("periodic", 90))

    if avg_motion < 20:
        methods.append(("fade", 80))
    elif diff_first_last < 30:
        methods.append(("cut", 85))

    methods.append(("pingpong", 70))

    if avg_motion > 50:
        methods.append(("morph", 65))

    methods.sort(key=lambda x: x[1], reverse=True)

    alternatives = [m[0] for m in methods[1:4]]
    recommended = methods[0][0] if methods else "hold"

    return {
        "recommended": recommended,
        "alternatives": alternatives,
        "analysis": analysis,
    }


def compute_frame_similarity(
    frame1: np.ndarray, frame2: np.ndarray, method: str = "optical_flow"
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

        # Use inverse of average motion magnitude as similarity
        # Less motion = more similar frames
        avg_motion = np.mean(magnitude)

        # Scale: 0 motion = 100 similarity, 20+ motion = 0 similarity
        similarity = max(0, 100 - avg_motion * 5)
        return float(similarity)

    elif method == "mse":
        mse = np.mean((frame1.astype(float) - frame2.astype(float)) ** 2)
        similarity = max(0, 100 - mse / 10)
        return float(similarity)

    else:
        raise ValueError(f"Unknown method: {method}")


def find_best_loop_points(
    frames: list[np.ndarray],
    scan_range: int = 100,
    threshold: float = 70.0,
    similarity_method: str = "optical_flow",
    show_progress: bool = False,
) -> tuple[int | None, int | None, float]:
    """
    Scan video for best loop points (start and end).

    Returns: (start_idx, end_idx, score)
    """
    n = len(frames)
    if n < scan_range * 2:
        scan_range = n // 4

    # Define scan ranges
    start_range = min(scan_range, n - scan_range)
    end_range_start = max(scan_range, n - scan_range)

    best_score = 0.0
    best_start = 0
    best_end = n - 1

    total_comparisons = start_range * (n - end_range_start)
    comparison_count = 0

    # Scan for best match points
    for start_idx in range(start_range):
        for end_idx in range(end_range_start, n):
            score = compute_frame_similarity(
                frames[start_idx], frames[end_idx], method=similarity_method
            )

            comparison_count += 1

            if show_progress and comparison_count % 100 == 0:
                prog = (
                    (comparison_count / total_comparisons) * 100
                    if total_comparisons > 0
                    else 0
                )
                print(
                    f"\rScanning for loop points: {prog:.1f}% ({comparison_count}/{total_comparisons})",
                    end="",
                )

            if score > best_score:
                best_score = score
                best_start = start_idx
                best_end = end_idx

    if show_progress:
        print()

    if best_score >= threshold:
        return (best_start, best_end, best_score)
    return (None, None, best_score)


def find_best_match_point(
    first_frames: list[np.ndarray],
    last_frames: list[np.ndarray],
    threshold: int = 85,
    similarity_method: str = "mse",
) -> tuple[int | None, int | None, float]:
    """Find best matching frame pair between first and last frames."""
    if not first_frames or not last_frames:
        return (None, None, 0.0)

    best_score = 0
    best_first_idx = 0
    best_last_idx = 0

    for i, first_frame in enumerate(first_frames):
        for j, last_frame in enumerate(last_frames):
            score = compute_frame_similarity(
                first_frame, last_frame, method=similarity_method
            )
            if score > best_score:
                best_score = score
                best_first_idx = i
                best_last_idx = j

    if best_score >= threshold:
        return (best_first_idx, best_last_idx, best_score)
    return (None, None, best_score)


def encode_video(frames: list[np.ndarray], output_path: str, fps: float, workers: int = 1) -> str:
    """Encode frames to video using FFmpeg without saving to disk."""
    if not frames:
        raise ValueError("No frames to encode")

    from core.video import VideoStreamWriter
    
    # Check if frames have alpha channel
    has_alpha = frames[0].shape[2] == 4 if len(frames[0].shape) == 3 else False
    height, width = frames[0].shape[:2]

    with VideoStreamWriter(
        output_path=output_path,
        fps=fps,
        width=width,
        height=height,
        has_alpha=has_alpha,
        loop=True,
        workers=workers
    ) as writer:
        for frame in frames:
            writer.write_frame(frame)

    return output_path


def create_loop(
    input_path: str,
    output_path: str,
    method: str = "auto",
    fade_color: str = "transparent",
    fade_frames: int = 10,
    fade_type: str = "both",
    morph_steps: int = 10,
    cycle_frames: int | None = None,
    hold_frames: int = 2,
    blend_mode: str = "add",
    ramp_factor: float = 1.0,
    analyze_only: bool = False,
    progress: bool = False,
    until: float | None = None,
    workers: int = 1,
) -> dict[str, Any]:
    """
    Main entry point for loop operation.

    Creates seamless infinite loops using various methods.

    Methods:
    - pingpong: Forward then backward (best for bouncing/pendulum/breathing)
    - morph: Optical flow warps (best for complex motion)
    - periodic: Auto-detect cycles (best for walking/running/waves)
    - hold: Freeze frames at transition (best for videos with pauses)
    - fade: Fade to color/transparent (best when nothing else works)
    - blend: Creative blend modes (best for artistic effects)
    - reverse: Forward then full reverse (best for reversible motion)
    - speedramp: Speed adjustment (best when endpoints almost match)
    - auto: Analyze and pick best method
    """
    result: dict[str, Any] = {"success": False, "output_path": None, "error": None}

    try:
        all_frames = extract_all_frames(input_path, show_progress=progress)

        if len(all_frames) < 4:
            result["error"] = "Video too short for looping (minimum 4 frames)"
            return result

        cap = cv2.VideoCapture(input_path)
        fps = 30.0
        if cap.isOpened():
            fps = cap.get(cv2.CAP_PROP_FPS)
            cap.release()

        if method == "auto":
            analysis = analyze_best_method(all_frames)
            if analyze_only:
                result["success"] = True
                result["analysis"] = analysis
                return result
            method = analysis["recommended"]

        if method == "pingpong":
            looped = create_pingpong_loop(all_frames, fps, until)
        elif method == "morph":
            looped = create_morph_loop(all_frames, morph_steps)
        elif method == "periodic":
            looped = create_periodic_loop(all_frames, cycle_frames)
        elif method == "hold":
            looped = create_hold_loop(all_frames, hold_frames)
        elif method == "fade":
            looped = create_fade_loop(all_frames, fade_color, fade_frames, fade_type)
        elif method == "blend":
            looped = create_blend_loop(all_frames, blend_mode)
        elif method == "reverse":
            looped = create_reverse_loop(all_frames)
        elif method == "speedramp":
            looped = create_speedramp_loop(all_frames, ramp_factor)
        else:
            looped = create_pingpong_loop(all_frames)

        encode_video(looped, output_path, fps, workers)

        result["success"] = True
        result["output_path"] = output_path

    except Exception as e:  # noqa: BLE001 - operation boundary reports any failure in `result`
        result["error"] = str(e)

    return result


register_operation(
    "loop",
    create_loop,
    {
        "method": {
            "type": "string",
            "default": "auto",
            "description": "Loop method: pingpong, morph, periodic, hold, fade, blend, reverse, speedramp, auto (default: auto)",
        },
        "fade_color": {
            "type": "string",
            "default": "transparent",
            "description": "Fade color: 'transparent', hex (#RRGGBB), or BGR (0,255,0) (best for fade method)",
        },
        "fade_frames": {
            "type": "int",
            "default": 10,
            "description": "Number of frames for fade transition (best for fade method)",
        },
        "fade_type": {
            "type": "string",
            "default": "both",
            "description": "Fade type: in, out, or both (best for fade method)",
        },
        "morph_steps": {
            "type": "int",
            "default": 10,
            "description": "Number of warp steps for morph transition (best for morph method)",
        },
        "cycle_frames": {
            "type": "int",
            "default": None,
            "description": "Manual cycle length for periodic method (auto-detect if not set, best for periodic)",
        },
        "hold_frames": {
            "type": "int",
            "default": 2,
            "description": "Number of frames to freeze at transition (best for hold method)",
        },
        "blend_mode": {
            "type": "string",
            "default": "add",
            "description": "Blend mode: add, multiply, screen, overlay (best for blend method)",
        },
        "ramp_factor": {
            "type": "float",
            "default": 1.0,
            "description": "Speed multiplier 0.8-1.2 for speedramp (best for speedramp method)",
        },
        "analyze_only": {
            "type": "bool",
            "default": False,
            "description": "Just analyze and report best method, don't process video",
        },
        "until": {
            "type": "float",
            "default": None,
            "short": "-u",
            "description": "Start pingpong from this second (negative means from end)",
        },
        "workers": {
            "type": "int",
            "default": 1,
            "short": "-w",
            "description": "Number of worker threads (default: 1)",
        },
    },
    description="Create seamless infinite video loops with various methods",
)
