# Frame - Composable Video Processing CLI

Transform videos with composable operations. Built on FFmpeg, designed for pipelines.

## ✨ Features

- **Composable operations**: Chain multiple video transformations
- **Simple CLI**: `python cli.py input.mp4 output.webm fps-boost --to 60`
- **Config support**: Use JSON configs for complex operations
- **Modular**: Each operation is independent and extensible
- **Video looping**: Create seamless infinite loops with optical flow matching

## 🚀 Quick Start

```bash
# Install dependencies
pip install -r requirements.txt

# Boost FPS to 60
python cli.py input.mp4 output.mp4 fps-boost --to 60

# Remove background
python cli.py input.mp4 output.webm remove-bg --tolerance 30

# Use config file for complex operations
python cli.py input.mp4 output.webm remove-bg --config config.json
```

## 📦 Operations

### `fps-boost`
Increase video frame rate using FFmpeg's minterpolate filter.

```bash
python cli.py input.mp4 output.mp4 fps-boost --to 60
```

**Options:**
- `--to` - Target FPS (default: 60)

---

### `remove-bg`
Remove background from video with alpha channel support.

```bash
python cli.py input.mp4 output.webm remove-bg --tolerance 30 --edges 5
```

**Options:**
- `--color` - Background color (BGR: "0,255,0" or hex: "#00FF00")
- `--tolerance` - Color tolerance (default: 30)
- `--edges` - Soft edge size (default: 5)
- `--auto-ranges` - Auto-generate color ranges (default: on)
- `--num-ranges` - Number of color ranges (default: 5)
- `--method` - Detection: color, motion, or combined (default: color)
- `--edge-cleanup` - Remove color spill from edges (default: 3)
- `--adaptive-bg` - Detect background per-frame
- `--refine` - Enable refinement pass
- `--loop` - Enable infinite loop for output (default: on)

---

### `loop`
Create seamless infinite video loops with various methods.

**Which method to use:**

| Method | Best For |
|--------|----------|
| `pingpong` | Bouncing objects, pendulum, breathing |
| `morph` | Complex motion, fluid dynamics |
| `periodic` | Walking, running, waves, rhythmic motion |
| `hold` | Videos with natural pauses/holds |
| `fade` | When nothing else works (masks seams) |
| `blend` | Creative transitions |
| `reverse` | Water ripples, fire, particles |
| `speedramp` | Endpoints almost match, need speed tweak |
| `auto` | Auto-detect best method |

```bash
# Pingpong - forward then backward (best for bouncing/breathing)
python cli.py input.webm output.webm loop --method pingpong

# Morph - optical flow warps (best for complex motion)
python cli.py input.webm output.webm loop --method morph --morph-steps 15

# Periodic - auto-detect walking/running cycles
python cli.py input.webm output.webm loop --method periodic

# Hold - freeze briefly at transition
python cli.py input.webm output.webm loop --method hold --hold-frames 3

# Fade - fade to transparent (best for background-removed videos!)
python cli.py input.webm output.webm loop --method fade --fade-color transparent

# Fade - fade to custom color
python cli.py input.webm output.webm loop --method fade --fade-color "#FF0000"

# Blend - creative add blend
python cli.py input.webm output.webm loop --method blend --blend-mode add

# Reverse - forward then reverse
python cli.py input.webm output.webm loop --method reverse

# Speedramp - slight speed adjustment
python cli.py input.webm output.webm loop --method speedramp --ramp-factor 1.1

# Auto - analyze and pick best method
python cli.py input.webm output.webm loop --method auto

# Just analyze (don't process)
python cli.py input.webm output.webm loop --method auto --analyze-only
```

**Options:**
- `--method` - Loop method (default: auto)
- `--fade-color` - Color for fade: "transparent", hex (#RRGGBB), or BGR (default: transparent)
- `--fade-frames` - Frames for fade (default: 10)
- `--fade-type` - "in", "out", or "both" (default: both)
- `--morph-steps` - Warp steps for morph (default: 10)
- `--cycle-frames` - Manual cycle length for periodic
- `--hold-frames` - Freeze frames for hold (default: 2)
- `--blend-mode` - add, multiply, screen, overlay (default: add)
- `--ramp-factor` - Speed 0.8-1.2 for speedramp (default: 1.0)
- `--analyze-only` - Just analyze, don't process

---

## 🔧 Configuration Files

For complex operations with many options, use a JSON config:

**config.json:**
```json
{
  "bg": {
    "tolerance": 30,
    "edges": 5,
    "method": "color",
    "adaptive_bg": true,
    "refine": true
  },
  "fps": {
    "to": 60
  }
}
```

```bash
# Apply specific operation from config
python cli.py input.mp4 output.webm remove-bg --config config.json
```

**Note**: When using `--config`, other CLI flags for that operation are not allowed (exclusive).

## 💡 Examples

```bash
# Remove green screen and boost to 60fps (two separate operations)
python cli.py input.mp4 output.webm remove-bg --tolerance 25
python cli.py output.webm final.mp4 fps-boost --to 60

# Using config for fine-tuned removal
python cli.py input.mp4 output.webm remove-bg --config advanced_removal.json

# Auto-detect background color
python cli.py input.mp4 output.webm remove-bg

# Loop background-removed video with fade to transparent
python cli.py input.webm output.webm loop --method fade --fade-color transparent

# Loop with pingpong (forward + backward)
python cli.py input.webm output.webm loop --method pingpong

# Auto-detect best loop method
python cli.py input.webm output.webm loop --method auto

# Analyze video to find best method (no processing)
python cli.py input.webm output.webm loop --method auto --analyze-only

# Quick loop test with lower threshold
python cli.py input.webm output.webm loop --scan-frames 30 --match-threshold 40
```

## 📁 Project Structure

```
frame/
├── cli.py              # Entry point
├── framer.py           # Core library
├── core/               # Pipeline executor
│   └── __init__.py
├── ops/                # Operations
│   ├── __init__.py    # Registry
│   ├── remove_bg.py   # Background removal
│   ├── fps_boost.py   # FPS boost
│   └── loop.py        # Video looping
└── tests/
```

## 🔌 Adding New Operations

Operations are registered via decorator:

```python
from core import register_operation

@register_operation(
    name="my-op",
    args_schema={
        "param1": {"type": "int", "default": 10, "description": "Param description"}
    },
    description="My operation description"
)
def my_operation(input_path, output_path, param1=10):
    # Process video
    return {"success": True, "output_path": output_path}
```

## 📋 Requirements

- Python 3.9+
- FFmpeg (installed and in PATH)

## 🛠️ Development

```bash
# Run tests
python -m pytest tests/

# Test specific operation
python cli.py test_input.mp4 test_output.mp4 fps-boost --to 60
```

## 📄 License

[MIT](LICENSE)
