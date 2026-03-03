# Background Remover for MP4 Videos

Remove backgrounds from MP4 videos using color-based segmentation.

## Features

- Remove background from MP4 videos with transparent backgrounds
- Support for green screen, blue screen, or any solid color background
- Configurable color tolerance for imperfect backgrounds
- Soft edge transition for better quality
- Auto-color detection from video
- Multiple detection methods: color, motion, or combined
- Refinement pass to catch missed background pixels
- Multiple API options: CLI tool, Python library, or agent wrapper

## Installation

```bash
pip install -r requirements.txt
```

## Usage

### CLI Tool

```bash
python cli.py input.mp4 output.webm -c "0,255,0" -t 30
```

### CLI Options

| Option | Alias | Values | Default | Description |
|--------|-------|--------|---------|-------------|
| `input` | - | file | *required | Input video file |
| `output` | - | file | *required | Output video file |
| `-c` | `--color` | BGR string or hex | auto-detect | Background color (e.g., "0,255,0" or "#00FF00") |
| `-t` | `--tolerance` | 0-100 | 30 | Color matching tolerance |
| `-e` | `--edges` | 0+ | 5 | Soft edge size (0 = hard edge) |
| `-p` | `--progress` | flag | off | Show progress bar |
| `-n` | `--num-ranges` | 1-20 | 5 | Number of auto-generated color ranges |
| `-f` | `--format` | mov, webm | auto | Output format |
| `-m` | `--method` | color, motion, combined | color | Detection method |
| | `--motion-frames` | 1-100 | 30 | Frames to analyze for motion detection |
| | `--edge-cleanup` | 0-20 | 3 | Pixels to erode from edges to remove color spill |
| | `--adaptive-bg` | flag | off | Detect background per-frame from borders |
| | `--refine` | flag | off | Enable refinement pass to catch missed background colors |
| | `--refine-tolerance` | 0-100 | 45 | Color tolerance for refinement detection |
| | `--refine-block-size` | 8-128 | 32 | Block size for section analysis in refinement |
| | `--refine-interactive` | flag | off | Manual review per frame (requires display) |
| | `--refine-save-previews` | flag | off | Save preview images with flagged areas |

### Detection Methods

- **color** (default) - Uses color segmentation to detect background
- **motion** - Detects moving objects as foreground (good for moving subjects against static background)
- **combined** - Uses both color and motion for best results

### Examples

#### Remove Green Screen Background

```bash
python cli.py input.mp4 output.webm -c "0,255,0" -t 30
```

#### Remove Blue Screen Background

```bash
python cli.py input.mp4 output.webm -c "255,0,0" -t 30
```

#### Auto-Detect Background Color

```bash
python cli.py input.mp4 output.webm
```

#### Use Motion Detection (for moving subjects)

```bash
python cli.py input.mp4 output.webm -m motion
```

#### Combined Method (best quality)

```bash
python cli.py input.mp4 output.webm -m combined
```

#### Adaptive Background (varying lighting)

```bash
python cli.py input.mp4 output.webm --adaptive-bg
```

#### With Refinement Pass

```bash
python cli.py input.mp4 output.webm --refine --refine-tolerance 50
```

#### Recommended: Combined + Adaptive + Refinement

```bash
python cli.py input.mp4 output.webm \
    -e 0 \
    -t 30 \
    --adaptive-bg \
    -m combined \
    -p \
    --refine \
    --refine-block-size 20 \
    --refine-tolerance 80 \
    --edge-cleanup
```

**Explanation:**
- `-e 0` - No soft edges (hard edge for cleaner initial mask)
- `-t 30` - Initial color tolerance
- `--adaptive-bg` - Detect background per-frame (better for varying lighting)
- `-m combined` - Use both color and motion detection
- `-p` - Show progress
- `--refine` - Enable refinement pass to catch missed background pixels
- `--refine-block-size 20` - Smaller blocks for finer detection
- `--refine-tolerance 80` - Higher tolerance in refinement to catch edge cases
- `--edge-cleanup` - Run edge cleanup in refinement pass (after detecting missed backgrounds)

### Python Library

```python
from bgremover import remove_background, VideoBackgroundRemover

# Simple usage
remove_background(
    input_path="input.mp4",
    output_path="output.webm",
    background_color=[0, 255, 0],  # Green
    tolerance=30,
    soft_edges=5
)

# Advanced usage with VideoBackgroundRemover
remover = VideoBackgroundRemover(color_space="hsv")
remover.add_color_range(
    target_color=[0, 255, 0],
    tolerance=30,
    soft_edges=5,
    min_saturation=50,
    min_value=50
)
remover.process_video("input.mp4", "output.webm")
```

### Python API

```python
from bgremover import remove_background

result = remove_background(
    input_path="input.mp4",
    output_path="output.webm",
    background_color=[0, 255, 0],
    tolerance=30,
    soft_edges=5,
    show_progress=True
)

if result["success"]:
    print(f"Output: {result['output_path']}")
else:
    print(f"Error: {result['error']}")
```

## Output Formats

The tool supports two output formats that support alpha channels:

- **WebM** (recommended) - VP9 codec with alpha channel
- **MOV** - ProRes or PNG codec with alpha channel

The format is automatically detected from the output file extension, or can be specified with `-f/--format`.

## Notes

- **Color Space**: HSV is recommended for better handling of lighting variations
- **Tuning**: Start with tolerance=30 and adjust based on your video's background uniformity
- **Soft Edges**: Use soft_edges > 0 for smoother transitions around the subject
- **Adaptive Background**: Use `--adaptive-bg` when lighting changes throughout the video
- **Refinement Pass**: The refinement pass scans each frame for missed background-colored pixels using three methods: pixel-by-pixel, block-based, and region detection. It's especially useful for catching edge cases that the initial pass misses.
- **Edge Cleanup**: When `--refine` is enabled, edge_cleanup runs in the refinement pass (after detecting missed backgrounds). When `--refine` is off, edge_cleanup runs in the first pass.
