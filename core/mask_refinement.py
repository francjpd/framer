import cv2
import numpy as np

from core.color_ranges import generate_color_ranges


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


def refine_frame(
    bgr_frame: np.ndarray,
    alpha: np.ndarray,
    background_color: list,
    tolerance: int = 45,
    block_size: int = 32,
    edge_cleanup: int | None = None,
    soft_edges: int | None = None,
) -> np.ndarray:
    """
    Refine a single frame to catch missed background-colored pixels inline.
    Returns the refined alpha mask.
    """
    color_ranges = generate_color_ranges(
        background_color, num_ranges=3, base_tolerance=tolerance
    )

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
