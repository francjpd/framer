"""
Recolor / Tint operation.
Replaces a specific color (or range of colors) with a new color.
"""

from typing import Any

import cv2
import numpy as np

from core import gpu_ops, register_operation
from core.gpu import is_available
from core.parallel import process_video_parallel
from core.utils import parse_color


def _apply_recolor(
    frame: np.ndarray,
    target_bgr: tuple,
    new_bgr: tuple,
    tolerance: int,
    use_gpu: bool = True,
) -> np.ndarray:
    """
    Frame processing function for recoloring.
    """
    if use_gpu and is_available():
        return gpu_ops.apply_color_replacement(frame, target_bgr, new_bgr, tolerance)

    # CPU fallback
    lower_bound = np.array([max(0, c - tolerance) for c in target_bgr], dtype=np.uint8)
    upper_bound = np.array(
        [min(255, c + tolerance) for c in target_bgr], dtype=np.uint8
    )

    bgr_frame = frame[:, :, :3]
    mask = cv2.inRange(bgr_frame, lower_bound, upper_bound)

    if cv2.countNonZero(mask) == 0:
        return frame

    out_frame = frame.copy()
    out_frame[mask > 0, 0] = new_bgr[0]
    out_frame[mask > 0, 1] = new_bgr[1]
    out_frame[mask > 0, 2] = new_bgr[2]

    return out_frame


def recolor_video(
    input_path: str,
    output_path: str,
    target: str,
    new_color: str,
    tolerance: int = 30,
    workers: int | None = None,
    progress: bool = False,
    force_cpu: bool = False,
) -> dict[str, Any]:
    """Replace a target color with a new color in the video."""
    from core.gpu import notify_gpu_usage

    target_bgr = parse_color(target)
    new_bgr = parse_color(new_color)

    use_gpu = is_available() and not force_cpu
    if use_gpu:
        notify_gpu_usage()

    result = process_video_parallel(
        input_path=input_path,
        output_path=output_path,
        process_func=_apply_recolor,
        func_kwargs={
            "target_bgr": target_bgr,
            "new_bgr": new_bgr,
            "tolerance": tolerance,
            "use_gpu": use_gpu,
        },
        workers=workers,
        show_progress=progress,
    )

    return result


register_operation(
    name="recolor",
    func=recolor_video,
    args_schema={
        "target": {
            "type": "string",
            "short": "-t",
            "description": "Target color to replace (hex or BGR)",
        },
        "new_color": {
            "type": "string",
            "short": "-n",
            "description": "New color to apply (hex or BGR)",
        },
        "tolerance": {
            "type": "int",
            "default": 30,
            "description": "Color matching tolerance",
        },
        "workers": {
            "type": "int",
            "default": 1,
            "short": "-w",
            "description": "Number of worker threads",
        },
    },
    description="Replace a specific color or color range with a new color",
)
