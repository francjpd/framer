# Background Remover for MP4 Videos

Remove backgrounds from MP4 videos using color-based segmentation.

## Features

- Remove background from MP4 videos with transparent backgrounds
- Support for green screen, blue screen, or any solid color background
- Configurable color tolerance for imperfect backgrounds
- Soft edge transition for better quality
- Multiple API options: CLI tool, Python library, or agent wrapper

## Installation

```bash
pip install -r requirements.txt
```

## Usage

### CLI Tool

```bash
python remove_bg.py input.mp4 output.mp4 -c "0,255,0" -t 30
```

**Arguments:**
- `input` - Input video file path
- `output` - Output video file path  
- `-c, --color` - Target background color in BGR format (default: '0,255,0')
- `-t, --tolerance` - Color tolerance (0-100, default: 30)
- `-e, --edges` - Soft edge size (0 = hard edge, default: 5)
- `-s, --space` - Color space: 'hsv' or 'bgr' (default: 'hsv')
- `-p, --progress` - Show processing progress

### Python Library

```python
from bgremover import remove_background, VideoBackgroundRemover

# Simple usage
remove_background(
    input_path="input.mp4",
    output_path="output.mp4",
    background_color=[0, 255, 0],  # Green
    tolerance=30,
    soft_edges=5
)

# Advanced usage with custom settings
remover = VideoBackgroundRemover(color_space="hsv")
remover.add_color_range(
    target_color=[0, 255, 0],
    tolerance=30,
    soft_edges=5,
    min_saturation=50,
    min_value=50
)
remover.process_video("input.mp4", "output.mp4")
```

### AI Agent Wrapper

```python
from agent_wrapper import remove_video_background

result = remove_video_background(
    input_path="input.mp4",
    output_path="output.mp4",
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

## Examples

### Remove Green Screen Background

```bash
python remove_bg.py input.mp4 output.mp4 -c "0,255,0" -t 30
```

### Remove Blue Screen Background

```bash
python remove_bg.py input.mp4 output.mp4 -c "255,0,0" -t 30
```

### Multiple Color Ranges (Python)

```python
from agent_wrapper import remove_video_background_multi_color

result = remove_video_background_multi_color(
    input_path="input.mp4",
    output_path="output.mp4",
    color_ranges=[
        {"color": [0, 255, 0], "tolerance": 25},
        {"color": [10, 250, 10], "tolerance": 30},
    ]
)
```

## Notes

- **Output Format**: The output video maintains the MP4 container but includes an alpha channel.
- **Color Space**: HSV is recommended for better handling of lighting variations.
- **Tuning**: Start with tolerance=30 and adjust based on your video's background uniformity.
- **Soft Edges**: Use soft_edges > 0 for smoother transitions around the subject.
