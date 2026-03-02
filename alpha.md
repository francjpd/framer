# Background Remover - Alpha Channel Support

## Overview

This project provides tools to remove backgrounds from videos, outputting files with alpha channel (transparency) support.

## Features

### Auto-Detect Background Color
Automatically detects background color from video borders:
- Samples 5x5 corners from frame 0, frame 1, and last frame
- If colors match within tolerance, uses single color
- If colors differ, adds all unique colors to removal range
- Default tolerance: 25

### Hex Color Support
Supports multiple color input formats:
- BGR: `0,255,0`
- Hex with hash: `#00FF00`
- Hex without hash: `00FF00`

### Output Formats
Supports both MOV and WebM with alpha channel:
- **MOV**: Uses qtrle codec (reliable alpha)
- **WebM**: Uses VP9 codec with `-auto-alt-ref 0` flag (required for alpha)

## Installation

```bash
pip install -r requirements.txt
```

Requires: OpenCV, NumPy, FFmpeg

## Usage

### CLI

```bash
# Auto-detect background + WebM output (recommended)
python cli.py input.mp4 output.webm

# Auto-detect background + MOV output
python cli.py input.mp4 output.mov

# Manual color + WebM
python cli.py input.mp4 output.webm -c "#00FF00"

# Manual color + MOV
python cli.py input.mp4 output.mov -c "0,255,0"

# Motion-based detection (for similar bg/subject colors)
python cli.py input.mp4 output.webm -m motion

# Combined method
python cli.py input.mp4 output.webm -m combined

# With flags
python cli.py input.mp4 output --format webm -t 30 -e 5 -p
```

### Python API

```python
from bgremover import remove_background

# Auto-detect background + WebM output
result = remove_video_background(
    input_path="video.mp4",
    output_path="output.webm"
)

# Manual color + MOV output
result = remove_video_background(
    input_path="video.mp4",
    output_path="output.mov",
    background_color="#00FF00"
)

if result["success"]:
    print(f"Output: {result['output_path']}")
else:
    print(f"Error: {result['error']}")
```

### Library Usage

```python
from bgremover import VideoBackgroundRemover, detect_background_color_from_video

# Auto-detect color
colors = detect_background_color_from_video("input.mp4", tolerance=25)

# Process with detected colors
remover = VideoBackgroundRemover(color_space="bgr")
for color in colors:
    remover.add_color_range(target_color=color, tolerance=30)

remover.process_video("input.mp4", "output.mov", show_progress=True)
```

## CLI Options

| Flag | Description | Default |
|------|-------------|---------|
| `-c, --color` | Background color (BGR or hex) | Auto-detect |
| `-t, --tolerance` | Color tolerance (0-100) | 30 |
| `-e, --edges` | Soft edge size (0=hard) | 5 |
| `-s, --space` | Color space (hsv/bgr) | hsv |
| `-f, --format` | Output format (mov/webm) | Auto from extension |
| `-p, --progress` | Show progress | False |
| `--auto-ranges` | Auto-generate color ranges | True |
| `-n, --num-ranges` | Number of auto-ranges | 5 |
| `-m, --method` | Detection method: color/motion/combined | color |
| `--motion-frames` | Frames to analyze for motion | 30 |
| `--edge-cleanup` | Pixels to erode from edges (removes color spill) | 3 |

### Detection Methods

- **color** (default): Uses color-based segmentation. Works well when subject and background have distinct colors.
- **motion**: Uses frame differencing to detect moving subject. Best for videos where subject moves against static background.
- **combined**: Combines both color and motion detection for more robust results.

The **motion** method is recommended for videos like `octopus-green.mp4` where the subject and background have similar colors but the subject is moving.

## Key Technical Details

### WebM Alpha Encoding

The critical fix for WebM alpha support is the `-auto-alt-ref 0` flag:

```python
cmd = [
    "ffmpeg",
    "-y",
    "-framerate", str(fps),
    "-i", str(frames_dir / "frame_%05d.png"),
    "-c:v", "libvpx-vp9",
    "-pix_fmt", "yuva420p",
    "-auto-alt-ref", "0",  # CRITICAL for alpha
    "-crf", "30",
    "-b:v", "0",
    str(final_output),
]
```

Without this flag, VP9 encodes the alpha metadata but loses the actual alpha channel data.

### Color Detection

The detection samples corners from:
1. Frame 0 (first frame)
2. Frame 1 (second frame)  
3. Last frame

Each frame samples 4 corners (5x5 pixels each), for 12 total samples. Colors within tolerance are clustered together.

## Files

| File | Description |
|------|-------------|
| `bgremover.py` | Core library (VideoBackgroundRemover class) |
| `cli.py` | CLI tool with alpha support |
| `cli.py` | Python API wrapper |

## Known Issues

- WebM alpha requires FFmpeg with VP9 support
- Some video players may not display WebM alpha correctly (Chrome works)
- MOV format is more reliable for alpha across players

## Changelog

### Latest (2026-02-26)

- Auto-detect background color from video borders
- Hex color input support (#RRGGBB)
- WebM output with alpha channel
- Fixed VP9 alpha encoding with `-auto-alt-ref 0`
- Added motion-based detection method (-m motion/combined) for videos where subject and background have similar colors
