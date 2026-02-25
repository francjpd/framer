#!/usr/bin/env python3
"""
CLI tool to remove background from MP4 videos.
"""

import argparse
import sys

from bgremover import remove_background


def parse_color(color_str):
    """Parse BGR color string in format 'B,G,R'."""
    try:
        values = [int(x.strip()) for x in color_str.split(",")]
        if len(values) != 3:
            raise ValueError
        return values
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid color format: '{color_str}'. Use 'B,G,R' (e.g., '0,255,0' for green)"
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
        default="0,255,0",
        help="Target background color in BGR format (default: '0,255,0' - green)",
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
        output_path = remove_background(
            input_path=args.input,
            output_path=args.output,
            background_color=args.color,
            tolerance=args.tolerance,
            soft_edges=args.edges,
            color_space=args.space,
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
