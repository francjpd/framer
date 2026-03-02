# Background Remover for MP4 Videos

Remove backgrounds from MP4 videos using color-based segmentation.

## Features

- Remove background from MP4 videos with transparent backgrounds
- Support for green screen, blue screen, or any solid color background
- Configurable color tolerance for imperfect backgrounds
- Soft edge transition for better quality
- Auto-color detection from video
- Multiple detection methods: color, motion, or combined
- Hole filling and flood fill for cleaner masks
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
| | `--hole-fill` | 0-100 | 25 | Fill holes smaller than size (0=disable) |
| | `--flood-fill` | flag | off | Fill trapped internal background pixels |

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

#### With Hole Filling and Flood Fill

```bash
python cli.py input.mp4 output.webm --hole-fill 25 --flood-fill
```

#### Full Example with All Options

```bash
python cli.py input.mp4 output.webm \
    -c "0,255,0" \
    -t 30 \
    -e 5 \
    -n 10 \
    -m combined \
    --motion-frames 30 \
    --edge-cleanup 3 \
    --adaptive-bg \
    --hole-fill 25 \
    --flood-fill \
    -p
```

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

### AI Agent Wrapper

```python
from cli import remove_video_background

result = remove_video_background(
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
- **Hole Filling**: Use `--hole-fill` to remove small gaps in the foreground mask
- **Flood Fill**: Use `--flood-fill` to fill larger enclosed background regions
