#!/usr/bin/env python3
"""
CLI tool for removing backgrounds from videos with alpha channel support.

Provides a simple command-line interface that validates inputs and calls
the core bgremover library for processing.

Usage:
    python cli.py input.mp4 output.webm -c "0,255,0" -t 30 -p

Options:
    -c, --color      Background color (BGR: "0,255,0", hex: "#00FF00")
    -t, --tolerance  Color tolerance (default: 30)
    -e, --edges      Soft edge size (default: 5)
    -p, --progress   Show progress bar
    -m, --method     Detection method: color (default), motion, combined
"""

import argparse
import sys

from bgremover import remove_background as bg_remove


def parse_color(color_str):
    """Parse color from BGR string, hex, or list."""
    if color_str is None:
        return None

    if isinstance(color_str, (list, tuple)):
        if len(color_str) == 3:
            return list(color_str)
        return None

    if isinstance(color_str, str):
        color_str = color_str.strip()
        if color_str.startswith("#"):
            color_str = color_str[1:]

        if len(color_str) == 6:
            try:
                r = int(color_str[0:2], 16)
                g = int(color_str[2:4], 16)
                b = int(color_str[4:6], 16)
                return [b, g, r]
            except ValueError:
                pass

        try:
            values = [int(x.strip()) for x in color_str.split(",")]
            if len(values) == 3:
                return values
        except ValueError:
            pass

    return None


def main():
    parser = argparse.ArgumentParser(description="Remove background with alpha channel")
    parser.add_argument("input", help="Input video")
    parser.add_argument("output", help="Output video")
    parser.add_argument(
        "-c",
        "--color",
        default=None,
        help="Background color (BGR: '0,255,0', hex: '#00FF00' or '00FF00'). Auto-detects if omitted.",
    )
    parser.add_argument("-t", "--tolerance", type=int, default=30)
    parser.add_argument("-e", "--edges", type=int, default=5)
    parser.add_argument("-p", "--progress", action="store_true")
    parser.add_argument(
        "--auto-ranges",
        action="store_true",
        dest="auto_ranges",
        default=True,
        help="Auto-generate color ranges (default)",
    )
    parser.add_argument(
        "--no-auto-ranges",
        action="store_false",
        dest="auto_ranges",
        help="Disable auto color ranges",
    )
    parser.add_argument(
        "-n",
        "--num-ranges",
        type=int,
        default=5,
        help="Number of auto-generated color ranges",
    )
    parser.add_argument(
        "-m",
        "--method",
        choices=["color", "motion", "combined"],
        default="color",
        help="Detection method: color (default), motion, combined",
    )
    parser.add_argument(
        "--motion-frames",
        type=int,
        default=30,
        help="Number of frames to analyze for motion detection (default: 30)",
    )
    parser.add_argument(
        "--edge-cleanup",
        type=int,
        default=3,
        help="Pixels to erode from edges to remove color spill (default: 3)",
    )
    parser.add_argument(
        "--adaptive-bg",
        action="store_true",
        default=False,
        help="Detect background per-frame from borders (better for varying lighting)",
    )
    parser.add_argument(
        "--hole-fill",
        type=int,
        default=25,
        help="Fill holes in mask smaller than this size (0 to disable, default: 25)",
    )
    parser.add_argument(
        "--flood-fill",
        action="store_true",
        default=False,
        help="Fill internal holes trapped between foreground pixels",
    )

    args = parser.parse_args()

    bg_color = parse_color(args.color)

    result = bg_remove(
        input_path=args.input,
        output_path=args.output,
        background_color=bg_color,
        tolerance=args.tolerance,
        soft_edges=args.edges,
        show_progress=args.progress,
        auto_ranges=args.auto_ranges,
        num_ranges=args.num_ranges,
        method=args.method,
        motion_frames=args.motion_frames,
        edge_cleanup=args.edge_cleanup,
        adaptive_bg=args.adaptive_bg,
        hole_fill=args.hole_fill,
        flood_fill=args.flood_fill,
    )

    if result["success"]:
        print(f"\n✅ Success! Output: {result['output_path']}")
    else:
        print(f"\n❌ Error: {result['error']}")
        sys.exit(1)


if __name__ == "__main__":
    main()
