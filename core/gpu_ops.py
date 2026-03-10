"""
GPU-Accelerated Operations.

Provides GPU-backed versions of common image processing operations.
Falls back to CPU (numpy/OpenCV) when GPU is not available.
"""

import numpy as np
from typing import Tuple, Optional, Union, List

from core.gpu import (
    get_backend,
    is_available,
    to_device,
    from_device,
    get_array_module,
    device_synchronize,
)


def color_distance(
    frame: np.ndarray,
    target_color: Union[Tuple[int, int, int], List[int], np.ndarray],
) -> np.ndarray:
    """
    Calculate Euclidean distance from each pixel to target color.

    Args:
        frame: BGR frame (H, W, 3)
        target_color: Target color [B, G, R]

    Returns:
        Distance array (H, W) where each pixel is distance to target
    """
    if is_available():
        return _color_distance_gpu(frame, target_color)
    return _color_distance_cpu(frame, target_color)


def _color_distance_gpu(frame: np.ndarray, target_color) -> np.ndarray:
    """GPU implementation of color_distance."""
    backend = get_backend()
    xp = get_array_module()
    device = to_device(frame)

    # Handle torch vs cupy API differences
    if backend == "torch" or (hasattr(xp, "__name__") and xp.__name__ == "torch"):
        target = xp.tensor(target_color, dtype=xp.float32)
    else:
        target = xp.array(target_color, dtype=xp.float32)
    target = target.reshape(1, 1, 3)

    dist = xp.sqrt(xp.sum((device.astype(xp.float32) - target) ** 2, axis=2))

    device_synchronize()
    result = from_device(dist)

    return result.astype(np.float32)


def _color_distance_cpu(frame: np.ndarray, target_color) -> np.ndarray:
    """CPU fallback for color_distance."""
    target = np.array(target_color, dtype=np.float32)
    frame_float = frame.astype(np.float32)
    dist = np.sqrt(np.sum((frame_float - target) ** 2, axis=2))
    return dist


def in_range(
    frame: np.ndarray,
    lower: Union[Tuple[int, int, int], List[int], np.ndarray],
    upper: Union[Tuple[int, int, int], List[int], np.ndarray],
) -> np.ndarray:
    """
    Create a binary mask for pixels within the specified range.
    GPU-accelerated version of cv2.inRange.

    Args:
        frame: BGR frame (H, W, 3)
        lower: Lower bound [B, G, R]
        upper: Upper bound [B, G, R]

    Returns:
        Binary mask (H, W) where 255 = in range, 0 = out of range
    """
    if is_available():
        return _in_range_gpu(frame, lower, upper)
    return _in_range_cpu(frame, lower, upper)


def _in_range_gpu(frame: np.ndarray, lower, upper) -> np.ndarray:
    """GPU implementation of in_range."""
    xp = get_array_module()
    device = to_device(frame)

    lower_arr = xp.array(lower, dtype=xp.uint8).reshape(1, 1, 3)
    upper_arr = xp.array(upper, dtype=xp.uint8).reshape(1, 1, 3)

    mask = xp.all((device >= lower_arr) & (device <= upper_arr), axis=2)
    mask = mask.astype(xp.uint8) * 255

    device_synchronize()
    result = from_device(mask)

    if xp.__name__ == "cupy":
        return result.astype(np.uint8)
    return result


def _in_range_cpu(frame: np.ndarray, lower, upper) -> np.ndarray:
    """CPU fallback for in_range."""
    import cv2

    lower_arr = np.array(lower, dtype=np.uint8)
    upper_arr = np.array(upper, dtype=np.uint8)
    return cv2.inRange(frame, lower_arr, upper_arr)


def gaussian_blur(
    frame: np.ndarray,
    kernel_size: int,
    sigma: float = 0,
) -> np.ndarray:
    """
    Apply Gaussian blur to a frame.
    GPU-accelerated version of cv2.GaussianBlur.

    Args:
        frame: Input frame (H, W, C) - supports BGRA
        kernel_size: Kernel size (must be odd)
        sigma: Gaussian kernel standard deviation

    Returns:
        Blurred frame
    """
    if is_available():
        return _gaussian_blur_gpu(frame, kernel_size, sigma)
    return _gaussian_blur_cpu(frame, kernel_size, sigma)


def _gaussian_blur_gpu(frame: np.ndarray, kernel_size, sigma) -> np.ndarray:
    """GPU implementation of gaussian_blur using CuPy/torch."""
    xp = get_array_module()

    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel_size = max(1, kernel_size)

    device = to_device(frame)

    if xp.__name__ == "cupy":
        import cupyx.scipy.ndimage as ndi

        blurred = ndi.gaussian_filter(device, sigma, mode="reflect")
    else:
        import torch.nn.functional as F
        import torch

        # For torch, use padding + conv2d for gaussian blur approximation
        pad = kernel_size // 2
        
        # Ensure we are using float tensor for conv2d
        x = device.float() if device.dtype == torch.uint8 else device

        # Add batch dim and apply
        x = (
            x.permute(2, 0, 1).unsqueeze(0)
            if x.dim() == 3
            else x.unsqueeze(0).unsqueeze(0)
        )
        
        # Create gaussian kernel
        ax = xp.arange(-kernel_size // 2 + 1.0, kernel_size // 2 + 1.0, device=x.device, dtype=x.dtype)
        xx, yy = xp.meshgrid(ax, ax, indexing='ij')
        
        if sigma > 0:
            kernel = xp.exp(-(xx**2 + yy**2) / (2.0 * sigma**2))
        else:
            kernel = xp.ones((kernel_size, kernel_size), device=x.device, dtype=x.dtype)
            
        kernel = kernel / kernel.sum()
        kernel = xp.flip(kernel, dims=[0, 1])  # Conv2d expects flipped kernel
        kernel = kernel.view(1, 1, kernel_size, kernel_size)
        kernel = kernel.repeat(x.shape[1], 1, 1, 1)

        x = F.pad(x, (pad, pad, pad, pad), mode="replicate")
        blurred = F.conv2d(x, kernel, groups=x.shape[1])
        
        blurred = blurred.squeeze(0)
        if device.dim() == 3:
            blurred = blurred.permute(1, 2, 0)
        else:
            blurred = blurred.squeeze(0)
            
        if device.dtype == torch.uint8:
            blurred = blurred.clamp(0, 255).to(torch.uint8)

    device_synchronize()
    return from_device(blurred)


def _gaussian_blur_cpu(frame: np.ndarray, kernel_size, sigma) -> np.ndarray:
    """CPU fallback for gaussian_blur."""
    import cv2

    if kernel_size % 2 == 0:
        kernel_size += 1
    return cv2.GaussianBlur(frame, (kernel_size, kernel_size), sigma)


def dilate(
    frame: np.ndarray,
    kernel_size: int,
    iterations: int = 1,
) -> np.ndarray:
    """
    Apply dilation to a binary mask.
    GPU-accelerated version of cv2.dilate.

    Args:
        frame: Binary mask (H, W) or BGRA (H, W, 4)
        kernel_size: Kernel size for dilation
        iterations: Number of dilation iterations

    Returns:
        Dilated frame
    """
    if is_available():
        return _dilate_gpu(frame, kernel_size, iterations)
    return _dilate_cpu(frame, kernel_size, iterations)


def _dilate_gpu(frame: np.ndarray, kernel_size, iterations) -> np.ndarray:
    """GPU implementation of dilate."""
    xp = get_array_module()

    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel_size = max(1, kernel_size)

    device = to_device(frame)

    if xp.__name__ == "cupy":
        import cupyx.scipy.ndimage as ndi

        kernel = xp.ones((kernel_size, kernel_size), dtype=xp.uint8)
        result = ndi.binary_dilation(device, structure=kernel, iterations=iterations)
        result = result.astype(xp.uint8) * 255
    else:
        import torch.nn as nn
        import torch.nn.functional as F
        import torch

        pad = kernel_size // 2
        x = device.float() if device.dtype == torch.uint8 else device
        
        x = (
            x.unsqueeze(0).unsqueeze(0)
            if x.dim() == 2
            else x.permute(2, 0, 1).unsqueeze(0)
        )
        for _ in range(iterations):
            x = F.max_pool2d(x, kernel_size, stride=1, padding=pad)
            
        result = x.squeeze(0)
        if device.dim() == 3:
            result = result.permute(1, 2, 0)
        else:
            result = result.squeeze(0)
            
        if device.dtype == torch.uint8:
            result = result.clamp(0, 255).to(torch.uint8)

    device_synchronize()
    return from_device(result)


def _dilate_cpu(frame: np.ndarray, kernel_size, iterations) -> np.ndarray:
    """CPU fallback for dilate."""
    import cv2

    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = np.ones((kernel_size, kernel_size), np.uint8)
    return cv2.dilate(frame, kernel, iterations=iterations)


def erode(
    frame: np.ndarray,
    kernel_size: int,
    iterations: int = 1,
) -> np.ndarray:
    """
    Apply erosion to a binary mask.
    GPU-accelerated version of cv2.erode.

    Args:
        frame: Binary mask (H, W) or BGRA (H, W, 4)
        kernel_size: Kernel size for erosion
        iterations: Number of erosion iterations

    Returns:
        Eroded frame
    """
    if is_available():
        return _erode_gpu(frame, kernel_size, iterations)
    return _erode_cpu(frame, kernel_size, iterations)


def _erode_gpu(frame: np.ndarray, kernel_size, iterations) -> np.ndarray:
    """GPU implementation of erode."""
    xp = get_array_module()

    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel_size = max(1, kernel_size)

    device = to_device(frame)

    if xp.__name__ == "cupy":
        import cupyx.scipy.ndimage as ndi

        kernel = xp.ones((kernel_size, kernel_size), dtype=xp.uint8)
        result = ndi.binary_erosion(device, structure=kernel, iterations=iterations)
        result = result.astype(xp.uint8) * 255
    else:
        import torch.nn as nn
        import torch.nn.functional as F
        import torch

        # For erosion, we need to invert, max_pool, then invert back
        if device.dtype == torch.uint8:
            inverted = 255.0 - device.float()
        else:
            inverted = 1.0 - device.float()
            
        pad = kernel_size // 2
        x = (
            inverted.unsqueeze(0).unsqueeze(0)
            if inverted.dim() == 2
            else inverted.permute(2, 0, 1).unsqueeze(0)
        )
        for _ in range(iterations):
            # max_pool on inverted image is equivalent to erosion
            x = F.max_pool2d(x, kernel_size, stride=1, padding=pad)
            
        result = x.squeeze(0)
        if device.dim() == 3:
            result = result.permute(1, 2, 0)
        else:
            result = result.squeeze(0)
            
        if device.dtype == torch.uint8:
            result = (255.0 - result).clamp(0, 255).to(torch.uint8)
        else:
            result = (1.0 - result)

    device_synchronize()
    return from_device(result)


def _erode_cpu(frame: np.ndarray, kernel_size, iterations) -> np.ndarray:
    """CPU fallback for erode."""
    import cv2

    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = np.ones((kernel_size, kernel_size), np.uint8)
    return cv2.erode(frame, kernel, iterations=iterations)


def merge_bgra(
    b: np.ndarray,
    g: np.ndarray,
    r: np.ndarray,
    alpha: np.ndarray,
) -> np.ndarray:
    """
    Merge B, G, R, and alpha channels into BGRA frame.
    GPU-accelerated version of cv2.merge.

    Args:
        b: Blue channel (H, W)
        g: Green channel (H, W)
        r: Red channel (H, W)
        alpha: Alpha channel (H, W)

    Returns:
        Merged BGRA frame (H, W, 4)
    """
    if is_available():
        return _merge_bgra_gpu(b, g, r, alpha)
    return _merge_bgra_cpu(b, g, r, alpha)


def _merge_bgra_gpu(b, g, r, alpha) -> np.ndarray:
    """GPU implementation of merge_bgra."""
    xp = get_array_module()

    b_dev = to_device(b)
    g_dev = to_device(g)
    r_dev = to_device(r)
    alpha_dev = to_device(alpha)

    # Stack channels
    result = xp.stack([b_dev, g_dev, r_dev, alpha_dev], axis=2)

    device_synchronize()
    return from_device(result)


def _merge_bgra_cpu(b, g, r, alpha) -> np.ndarray:
    """CPU fallback for merge_bgra."""
    import cv2

    return cv2.merge((b, g, r, alpha))


def split_bgra(
    frame: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """
    Split BGRA frame into individual channels.
    GPU-accelerated version of cv2.split.

    Args:
        frame: BGRA frame (H, W, 4)

    Returns:
        Tuple of (b, g, r, alpha) channels
    """
    if is_available():
        return _split_bgra_gpu(frame)
    return _split_bgra_cpu(frame)


def _split_bgra_gpu(
    frame: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """GPU implementation of split_bgra."""
    xp = get_array_module()

    device = to_device(frame)

    # Split along channel dimension
    channels = xp.split(device, 4, axis=2)

    device_synchronize()
    return tuple(from_device(ch) for ch in channels)


def _split_bgra_cpu(
    frame: np.ndarray,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """CPU fallback for split_bgra."""
    import cv2

    b, g, r, a = cv2.split(frame)
    return b, g, r, a


def threshold(
    frame: np.ndarray,
    threshold_value: int,
    max_value: int = 255,
) -> np.ndarray:
    """
    Apply binary threshold to a frame.
    GPU-accelerated version of cv2.threshold.

    Args:
        frame: Input frame (H, W) or (H, W, C)
        threshold_value: Threshold value (0-255)
        max_value: Maximum value for pixels above threshold

    Returns:
        Thresholded frame
    """
    if is_available():
        return _threshold_gpu(frame, threshold_value, max_value)
    return _threshold_cpu(frame, threshold_value, max_value)


def _threshold_gpu(frame: np.ndarray, threshold_value, max_value) -> np.ndarray:
    """GPU implementation of threshold."""
    xp = get_array_module()

    device = to_device(frame)

    result = xp.where(device > threshold_value, max_value, 0)

    device_synchronize()
    return from_device(result)


def _threshold_cpu(frame: np.ndarray, threshold_value, max_value) -> np.ndarray:
    """CPU fallback for threshold."""
    import cv2

    _, result = cv2.threshold(frame, threshold_value, max_value, cv2.THRESH_BINARY)
    return result


def bitwise_and(
    frame1: np.ndarray,
    frame2: np.ndarray,
) -> np.ndarray:
    """
    Perform bitwise AND between two frames.
    GPU-accelerated version of cv2.bitwise_and.

    Args:
        frame1: First frame
        frame2: Second frame

    Returns:
        Result of bitwise AND
    """
    if is_available():
        return _bitwise_and_gpu(frame1, frame2)
    return _bitwise_and_cpu(frame1, frame2)


def _bitwise_and_gpu(frame1, frame2) -> np.ndarray:
    """GPU implementation of bitwise_and."""
    xp = get_array_module()

    dev1 = to_device(frame1)
    dev2 = to_device(frame2)

    result = xp.bitwise_and(dev1, dev2)

    device_synchronize()
    return from_device(result)


def _bitwise_and_cpu(frame1, frame2) -> np.ndarray:
    """CPU fallback for bitwise_and."""
    import cv2

    return cv2.bitwise_and(frame1, frame2)


def bitwise_or(
    frame1: np.ndarray,
    frame2: np.ndarray,
) -> np.ndarray:
    """
    Perform bitwise OR between two frames.
    GPU-accelerated version of cv2.bitwise_or.

    Args:
        frame1: First frame
        frame2: Second frame

    Returns:
        Result of bitwise OR
    """
    if is_available():
        return _bitwise_or_gpu(frame1, frame2)
    return _bitwise_or_cpu(frame1, frame2)


def _bitwise_or_gpu(frame1, frame2) -> np.ndarray:
    """GPU implementation of bitwise_or."""
    xp = get_array_module()

    dev1 = to_device(frame1)
    dev2 = to_device(frame2)

    result = xp.bitwise_or(dev1, dev2)

    device_synchronize()
    return from_device(result)


def _bitwise_or_cpu(frame1, frame2) -> np.ndarray:
    """CPU fallback for bitwise_or."""
    import cv2

    return cv2.bitwise_or(frame1, frame2)


def bitwise_not(frame: np.ndarray) -> np.ndarray:
    """
    Perform bitwise NOT on a frame.
    GPU-accelerated version of cv2.bitwise_not.

    Args:
        frame: Input frame

    Returns:
        Result of bitwise NOT
    """
    if is_available():
        return _bitwise_not_gpu(frame)
    return _bitwise_not_cpu(frame)


def _bitwise_not_gpu(frame: np.ndarray) -> np.ndarray:
    """GPU implementation of bitwise_not."""
    xp = get_array_module()

    dev = to_device(frame)

    result = xp.bitwise_not(dev)

    device_synchronize()
    return from_device(result)


def _bitwise_not_cpu(frame: np.ndarray) -> np.ndarray:
    """CPU fallback for bitwise_not."""
    import cv2

    return cv2.bitwise_not(frame)


def composite(
    foreground: np.ndarray,
    background: np.ndarray,
    alpha: Optional[np.ndarray] = None,
) -> np.ndarray:
    """
    Composite foreground over background using alpha channel.

    Args:
        foreground: FG frame (H, W, 3) or (H, W, 4) with alpha
        background: BG frame (H, W, 3)
        alpha: Optional explicit alpha channel (H, W)

    Returns:
        Composited frame (H, W, 3)
    """
    if is_available():
        return _composite_gpu(foreground, background, alpha)
    return _composite_cpu(foreground, background, alpha)


def _composite_gpu(foreground, background, alpha) -> np.ndarray:
    """GPU implementation of composite."""
    xp = get_array_module()

    fg = to_device(foreground)
    bg = to_device(background)

    # Extract alpha if FG has 4 channels
    if fg.shape[2] == 4:
        if alpha is None:
            alpha = fg[:, :, 3]
        fg = fg[:, :, :3]

    if alpha is None:
        alpha = xp.ones_like(fg[:, :, 0]) * 255

    alpha_dev = to_device(alpha)
    alpha_fg = alpha_dev.astype(xp.float32) / 255.0
    alpha_fg = alpha_fg.reshape(fg.shape[0], fg.shape[1], 1)

    # Alpha blend
    result = fg.astype(xp.float32) * alpha_fg + bg.astype(xp.float32) * (1 - alpha_fg)
    result = xp.clip(result, 0, 255).astype(xp.uint8)

    device_synchronize()
    return from_device(result)


def _composite_cpu(foreground, background, alpha) -> np.ndarray:
    """CPU fallback for composite."""
    import cv2

    fg = foreground.copy()

    if fg.shape[2] == 4:
        if alpha is None:
            alpha = fg[:, :, 3]
        fg = fg[:, :, :3]

    if alpha is None:
        alpha = np.ones(fg.shape[:2], dtype=np.uint8) * 255

    alpha_fg = alpha.astype(np.float32) / 255.0
    alpha_fg = alpha_fg.reshape(fg.shape[0], fg.shape[1], 1)

    result = fg.astype(np.float32) * alpha_fg + background.astype(np.float32) * (
        1 - alpha_fg
    )
    result = np.clip(result, 0, 255).astype(np.uint8)

    return result


def apply_color_replacement(
    frame: np.ndarray,
    target_color: Tuple[int, int, int],
    new_color: Tuple[int, int, int],
    tolerance: int = 30,
) -> np.ndarray:
    """
    Replace pixels matching target_color with new_color.

    Args:
        frame: BGR frame (H, W, 3)
        target_color: Color to replace [B, G, R]
        new_color: Replacement color [B, G, R]
        tolerance: Color matching tolerance

    Returns:
        Frame with replaced colors
    """
    if is_available():
        return _apply_color_replacement_gpu(frame, target_color, new_color, tolerance)
    return _apply_color_replacement_cpu(frame, target_color, new_color, tolerance)


def _apply_color_replacement_gpu(
    frame, target_color, new_color, tolerance
) -> np.ndarray:
    """GPU implementation of color replacement."""
    xp = get_array_module()

    device = to_device(frame)

    # Create mask for pixels within tolerance
    target = xp.array(target_color, dtype=xp.uint8).reshape(1, 1, 3)
    lower = xp.clip(target - tolerance, 0, 255)
    upper = xp.clip(target + tolerance, 0, 255)

    mask = xp.all((device >= lower) & (device <= upper), axis=2)
    mask = mask.astype(xp.uint8)

    # Apply replacement
    new = xp.array(new_color, dtype=xp.uint8).reshape(1, 1, 3)
    result = xp.where(mask.reshape(mask.shape[0], mask.shape[1], 1) == 1, new, device)

    device_synchronize()
    return from_device(result)


def _apply_color_replacement_cpu(
    frame, target_color, new_color, tolerance
) -> np.ndarray:
    """CPU implementation of color replacement."""
    import cv2

    target = np.array(target_color, dtype=np.uint8)
    lower = np.clip(target - tolerance, 0, 255)
    upper = np.clip(target + tolerance, 0, 255)

    mask = cv2.inRange(frame, lower, upper)

    result = frame.copy()
    result[mask > 0] = new_color

    return result


def batch_process_frames(
    frames: List[np.ndarray], operation: str, **kwargs
) -> List[np.ndarray]:
    """
    Process multiple frames in a batch for better GPU utilization.

    Args:
        frames: List of frames to process
        operation: Operation name ('blur', 'dilate', 'erode', etc.)
        **kwargs: Operation-specific arguments

    Returns:
        List of processed frames
    """
    if not is_available():
        # Fall back to sequential CPU processing
        return _batch_process_cpu(frames, operation, **kwargs)

    # For GPU, process in chunks to manage memory
    chunk_size = kwargs.pop("chunk_size", 4)
    results = []

    for i in range(0, len(frames), chunk_size):
        chunk = frames[i : i + chunk_size]
        chunk_results = _process_chunk_gpu(chunk, operation, **kwargs)
        results.extend(chunk_results)

    return results


def _process_chunk_gpu(frames, operation, **kwargs):
    """Process a chunk of frames on GPU."""
    xp = get_array_module()

    # Stack frames into batch
    stacked = xp.stack([to_device(f) for f in frames], axis=0)

    # Apply operation based on type
    if operation == "blur":
        kernel_size = kwargs.get("kernel_size", 5)
        result = stacked
        # Process each frame - blur is already batch-compatible
        for i in range(len(frames)):
            result[i] = to_device(gaussian_blur(frames[i], kernel_size))
    else:
        # For other ops, process individually
        result = [from_device(to_device(f)) for f in frames]

    return [from_device(r) for r in result]


def _batch_process_cpu(frames, operation, **kwargs):
    """Fallback CPU batch processing."""
    results = []

    for frame in frames:
        if operation == "blur":
            results.append(gaussian_blur(frame, kwargs.get("kernel_size", 5)))
        elif operation == "dilate":
            results.append(
                dilate(frame, kwargs.get("kernel_size", 5), kwargs.get("iterations", 1))
            )
        elif operation == "erode":
            results.append(
                erode(frame, kwargs.get("kernel_size", 5), kwargs.get("iterations", 1))
            )
        else:
            results.append(frame)

    return results
