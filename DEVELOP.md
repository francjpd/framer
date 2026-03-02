# Developer Guide

This guide helps developers understand the codebase architecture and start contributing.

## Quick Start

```bash
# Clone and setup
pip install -r requirements.txt

# Run tests
pytest tests/

# Try the CLI
python cli.py input.mp4 output.webm -c "0,255,0" -p
```

## Architecture Overview

```
┌─────────────────────────────────────────┐
│           CLI Layer (cli.py)              │
│     argparse-based command interface     │
└────────────────────┬────────────────────┘
                     │ subprocess call
┌────────────────────▼────────────────────┐
│              API Layer (api.py)           │
│        Simple Python API function         │
└────────────────────┬────────────────────┘
                     │ imports
┌────────────────────▼────────────────────┐
│          Core Library (bgremover.py)     │
│   VideoBackgroundRemover class + utils   │
│           OpenCV image processing        │
└─────────────────────────────────────────┘
```

## Data Processing Pipeline

```
Input Video (MP4)
       │
       ▼
┌──────────────────┐
│  cv2.VideoCapture│
│    Read frames   │
└────────┬─────────┘
         │
         ▼
┌──────────────────────────────────┐
│      Detection Method            │
│  ┌─────────┐    ┌──────────┐   │
│  │  Color  │    │  Motion  │   │
│  │Based    │    │Based     │   │
│  └────┬────┘    └────┬─────┘   │
│       │               │          │
│       └───────┬───────┘          │
│               ▼                  │
│        Combine Masks             │
└─────────────┼───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│       Mask Refinement            │
│  - Soft edges (Gaussian blur)    │
│  - Edge cleanup (erode)         │
│  - Hole filling (morphology)    │
│  - Flood fill (optional)        │
└─────────────┼───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│      Create BGRA frame           │
│   Merge B,G,R channels + Alpha  │
└─────────────┼───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│    Save to PNG sequence          │
│    (temp directory)             │
└─────────────┼────────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│       FFmpeg Encode              │
│  - MOV: qtrle codec             │
│  - WebM: VP9 codec              │
│         (with alpha)             │
└─────────────┼────────────────────┘
               │
               ▼
    Output Video (.mov/.webm)
    with Alpha Channel
```

## Key Components

| File | Purpose | Key Functions/Classes |
|------|---------|----------------------|
| `bgremover.py` | Core library | `VideoBackgroundRemover`, `detect_background_color_*`, `fill_mask_holes`, `detect_motion_region` |
| `cli.py` | CLI entry point | `remove_background()`, `_process_frame()`, `_encode_mov()`, `_encode_webm()` |
| `api.py` | Simple API | `remove_video_background()` |
| `tests/` | Unit tests | `test_bgremover.py` |

## Entry Points

### 1. CLI (Most Common)
```bash
python cli.py input.mp4 output.webm -c "0,255,0" -t 30 -p
```

### 2. Python Library
```python
from bgremover import VideoBackgroundRemover

remover = VideoBackgroundRemover(color_space="hsv")
remover.add_color_range(target_color=[0,255,0], tolerance=30)
remover.process_video("input.mp4", "output.webm")
```

### 3. Agent Wrapper
```python
from api import remove_video_background

result = remove_video_background(
    input_path="input.mp4",
    output_path="output.webm",
    background_color=[0, 255, 0]
)
```

## Where to Start

| Goal | Read First |
|------|-----------|
| Understand core algorithm | `bgremover.py` - `_create_bgr_mask()`, `_create_hsv_mask()` |
| Add CLI option | `cli.py` - argparse section (bottom of file) |
| Add/modify detection | `bgremover.py` - `detect_motion_region()` |
| Improve mask quality | `bgremover.py` - `fill_mask_holes()`, `fill_internal_holes()` |
| Fix FFmpeg encoding | `cli.py` - `_encode_mov()`, `_encode_webm()` |

## Key Algorithms

### Color-Based Detection
- Convert frame to HSV or BGR color space
- Create mask using `cv2.inRange()` with lower/upper bounds
- Combine multiple color ranges with OR logic

### Motion Detection
- Frame differencing between consecutive frames
- Threshold to create binary motion mask
- Dilate to fill gaps

### Mask Refinement
- **Soft edges**: Gaussian blur on mask boundary
- **Hole filling**: Morphological closing (`cv2.morphologyEx`)
- **Flood fill**: Find contours, fill enclosed regions

## Important Notes

### Why PNG + FFmpeg?
OpenCV's `VideoWriter` doesn't support 4-channel (BGRA) video output natively. The workaround:
1. Process frames and save as PNG with alpha
2. Use FFmpeg to encode PNG sequence to MOV/WebM with alpha

### Alpha Encoding
- **MOV**: Uses `qtrle` codec (reliable alpha)
- **WebM**: Uses VP9 with `-auto-alt-ref 0` (critical for alpha)

## Testing

```bash
# Run all tests
pytest tests/

# Run specific test file
pytest tests/test_bgremover.py -v
```

## Adding New Features

1. **New CLI option**: Add to argparse in `cli.py`
2. **New detection method**: Add function in `bgremover.py`, integrate in `cli.py`
3. **New mask refinement**: Add function in `bgremover.py`, call in pipeline

## Debugging Tips

- Use `-p/--progress` to see processing progress
- Use `--format mov` for more reliable alpha output
- Check intermediate PNG frames in temp directory
- Enable `-e 0` to see raw mask without soft edges
