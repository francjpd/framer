#!/usr/bin/env python3
"""
Regenerate the deform golden image.

Run from the repository root with the project venv:

    .venv/bin/python tests/generate_deform_golden.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tests.deform_scene import GOLDEN_PATH, render_golden_frame  # noqa: E402


def main() -> int:
    GOLDEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    image = render_golden_frame()
    if not cv2.imwrite(str(GOLDEN_PATH), image):
        print(f"failed to write {GOLDEN_PATH}", file=sys.stderr)
        return 1
    print(f"wrote {GOLDEN_PATH} ({image.shape[1]}x{image.shape[0]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
