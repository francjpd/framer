#!/usr/bin/env python3
"""
CLI tool to remove background from MP4 videos.
"""

import argparse
import sys
import re

from bgremover import VideoBackgroundRemover, detect_background_color_from_video


def parse_color(color_str):
    """Parse color string - supports BGR (B,G,R), hex (#RRGGBB or RRGGBB)."""
    color_str = color_str.strip()

    if color_str.startswith("#"):
        color_str = color_str[1:]

    if re.match(r"^[0-9A-Fa-f]{6}$", color_str):
        r = int(color_str[0:2], 16)
        g = int(color_str[2:4], 16)
        b = int(color_str[4:6], 16)
        return [b, g, r]

    try:
        values = [int(x.strip()) for x in color_str.split(",")]
        if len(values) != 3:
            raise ValueError
        return values
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid color format: '{color_str}'. Use 'B,G,R' (e.g., '0,255,0'), '#RRGGBB' (e.g., '#00FF00'), or 'RRGGBB' (e.g., '00FF00')"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Remove background from MP4 videos using color-based segmentation."
    )

    parser.add_argument("input", help="Input video file path")

    parser.add_argument("output", help="Output video file path")

    parser.add_argument(
        "-c",
        "--color",
        type=parse_color,
        default=None,
        help="Target background color (BGR: '0,255,0', hex: '#00FF00' or '00FF00'). If omitted, auto-detects from video borders.",
    )

    parser.add_argument(
        "-t",
        "--tolerance",
        type=int,
        default=30,
        help="Color tolerance for segmentation (higher = more lenient, default: 30)",
    )

    parser.add_argument(
        "-e",
        "--edges",
        type=int,
        default=5,
        help="Soft edge transition size (0 = hard edge, default: 5)",
    )

    parser.add_argument(
        "-s",
        "--space",
        choices=["hsv", "bgr"],
        default="hsv",
        help="Color space for segmentation (default: hsv)",
    )

    parser.add_argument(
        "-p", "--progress", action="store_true", help="Show processing progress"
    )

    args = parser.parse_args()

    try:
        remover = VideoBackgroundRemover(color_space=args.space)

        if args.color is not None:
            remover.add_color_range(
                target_color=args.color,
                tolerance=args.tolerance,
                soft_edges=args.edges,
            )
        else:
            print("Auto-detecting background color from video borders...")
            colors = detect_background_color_from_video(
                args.input, tolerance=args.tolerance
            )
            print(f"Detected colors: {colors}")
            for color in colors:
                remover.add_color_range(
                    target_color=color,
                    tolerance=args.tolerance,
                    soft_edges=args.edges,
                )

        output_path = remover.process_video(
            input_path=args.input,
            output_path=args.output,
            show_progress=args.progress,
        )

        print(f"✅ Background removed successfully!")
        print(f"Output saved to: {output_path}")
        return 0

    except Exception as e:
        print(f"❌ Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
