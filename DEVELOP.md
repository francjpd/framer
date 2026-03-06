# Developer Guide

This guide helps developers understand the codebase architecture and start contributing.

## Quick Start

You can set up this project using either `venv` or `conda`.

**Option 1: Python venv (Standard)**
```bash
# Clone and setup
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

**Option 2: Conda**
```bash
# Clone and setup
conda create -n framer python=3.10
conda activate framer
pip install -r requirements.txt
```
# Clone and setup
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Run tests
pytest tests/

# Try the CLI
python cli.py input.mp4 output.webm -c "0,255,0" -p
```

## Architecture Overview

┌─────────────────────────────────────────┐
│      CLI & Python API Layer (cli.py)    │
│   Command-line interface + Python API   │
└────────────────────┬────────────────────┘
                     │ imports
┌────────────────────▼────────────────────┐
│      Core Library (core/bg_removal.py)  │
│   VideoBackgroundRemover class + utils  │
│           OpenCV image processing       │
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
│  ┌─────────┐     ┌──────────┐    │
│  │  Color  │     │  Motion  │    │
│  │Based    │     │Based     │    │
│  └────┬────┘     └────┬─────┘    │
│       │               │          │
│       └───────┬───────┘          │
│               ▼                  │
│        Combine Masks             │
└──────────────┼───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│       Mask Refinement            │
│  - Soft edges (Gaussian blur)    │
│  - Edge cleanup (erode)          │
│  - Hole filling (morphology)     │
│  - Flood fill (optional)         │
└──────────────┼───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│      Create BGRA frame           │
│   Merge B,G,R channels + Alpha   │
└──────────────┼───────────────────┘
               │
               ▼
┌───────────────────────────────────┐
│    Save to PNG sequence           │
│    (temp directory)               │
└──────────────┼────────────────────┘
               │
               ▼
┌───────────────────────────────────┐
│       FFmpeg Encode               │
│  - MOV: qtrle codec               │
│  - WebM: VP9 codec                │
│         (with alpha)              │
└──────────────┼────────────────────┘
               │
               ▼
    Output Video (.mov/.webm)
    with Alpha Channel
```

## Key Components

| File | Purpose | Key Functions/Classes |
| --- | --- | --- |
| `core/bg_removal.py` | Core library | `VideoBackgroundRemover`, `detect_background_color_*`, `fill_mask_holes`, `detect_motion_region` |
| `cli.py` | CLI tool | Typer app |
| `tests/` | Unit tests | `test_bgremover.py` |

## Entry Points

### 1. CLI (Most Common)

```bash
python cli.py input.mp4 output.webm -c "0,255,0" -t 30 -p
```

### 2. Python Library

```python
from core.bg_removal import VideoBackgroundRemover

remover = VideoBackgroundRemover(color_space="hsv")
remover.add_color_range(target_color=[0,255,0], tolerance=30)
remover.process_video("input.mp4", "output.webm")
```

### 3. Python API
```python
from core.bg_removal import remove_background

result = remove_background(
    input_path="input.mp4",
    output_path="output.webm",
    background_color=[0, 255, 0]
)
```

## Where to Start

| Goal | Read First |
| --- | --- |
| Understand core algorithm | `core/bg_removal.py` - `_create_bgr_mask()`, `_create_hsv_mask()` |
| Add CLI option | `cli.py` - Typer `@app.command` |
| Add/modify detection | `core/bg_removal.py` - `detect_motion_region()` |
| Improve mask quality | `core/bg_removal.py` - `fill_mask_holes()`, `fill_internal_holes()` |
| Fix FFmpeg encoding | `core/video.py` - `VideoStreamWriter` |

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

1. **New CLI option**: Add to Typer command args in `cli.py`
2. **New detection method**: Add function in `core/bg_removal.py`, integrate in pipeline
3. **New mask refinement**: Add function in `core/bg_removal.py`, call in pipeline

## Debugging Tips

- Use `-p/--progress` to see processing progress
- Use `--format mov` for more reliable alpha output
- Check intermediate PNG frames in temp directory
- Enable `-e 0` to see raw mask without soft edges
