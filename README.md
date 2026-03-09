# Frame - Composable Video Processing CLI

Transform videos with composable operations. Built on FFmpeg, designed for pipelines.

## ✨ Features

- **Composable operations**: Chain multiple video transformations
- **Simple CLI**: `python cli.py remove-bg input.mp4 output.webm --color "0,255,0"`
- **Config support**: Use JSON configs for complex operations
- **Modular**: Each operation is independent and extensible
- **Video looping**: Create seamless infinite loops with optical flow matching
- **Multi-Core Processing**: Operations are automatically parallelized across all available CPU threads for maximum speed.

## 🚀 Quick Start

You can set up this project using either `venv` (Python's built-in tool) or `conda` (popular for data science and complex C-dependencies). 

**Option 1: Python venv (Standard)**
```bash
# Set up a virtual environment
python -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

**Option 2: Conda**
```bash
# Set up a conda environment
conda create -n framer python=3.10
conda activate framer

# Install dependencies
pip install -r requirements.txt
```
# Set up a virtual environment (recommended to avoid PEP 668 issues)
python -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Boost FPS to 60
python cli.py fps-boost input.mp4 output.mp4 --to 60

# Remove background
python cli.py remove-bg input.mp4 output.webm --tolerance 30

# Use config file for complex operations
python cli.py remove-bg input.mp4 output.webm --config config.json
```

## 📦 Operations

### `fps-boost`
Increase video frame rate using FFmpeg's minterpolate filter.

```bash
python cli.py fps-boost input.mp4 output.mp4 --to 60
```

**Options:**
- `--to` - Target FPS (default: 60)
- `--workers` or `-w` - Number of CPU threads to use (defaults to all cores)

---

### `remove-bg`
Remove background from video with alpha channel support.

```bash
python cli.py remove-bg input.mp4 output.webm --tolerance 30 --edges 5
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
- `--workers` or `-w` - Number of CPU threads to use (defaults to all cores)

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
python cli.py loop input.webm output.webm --method pingpong

# Morph - optical flow warps (best for complex motion)
python cli.py loop input.webm output.webm --method morph --morph-steps 15

# Periodic - auto-detect walking/running cycles
python cli.py loop input.webm output.webm --method periodic

# Hold - freeze briefly at transition
python cli.py loop input.webm output.webm --method hold --hold-frames 3

# Fade - fade to transparent (best for background-removed videos!)
python cli.py loop input.webm output.webm --method fade --fade-color transparent

# Fade - fade to custom color
python cli.py loop input.webm output.webm --method fade --fade-color "#FF0000"

# Blend - creative add blend
python cli.py loop input.webm output.webm --method blend --blend-mode add

# Reverse - forward then reverse
python cli.py loop input.webm output.webm --method reverse

# Speedramp - slight speed adjustment
python cli.py loop input.webm output.webm --method speedramp --ramp-factor 1.1

# Auto - analyze and pick best method
python cli.py loop input.webm output.webm --method auto

# Just analyze (don't process)
python cli.py loop input.webm output.webm --method auto --analyze-only
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
- `--workers` or `-w` - Number of CPU threads to use (defaults to all cores)

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
python cli.py remove-bg input.mp4 output.webm --config config.json
```

**Note**: When using `--config`, other CLI flags for that operation are not allowed (exclusive).

## 💡 Examples

```bash
# Remove green screen and boost to 60fps (two separate operations)
python cli.py remove-bg input.mp4 output.webm --tolerance 25
python cli.py fps-boost output.webm final.mp4 --to 60

# Using config for fine-tuned removal
python cli.py remove-bg input.mp4 output.webm --config advanced_removal.json

# Auto-detect background color
python cli.py remove-bg input.mp4 output.webm

# Loop background-removed video with fade to transparent
python cli.py loop input.webm output.webm --method fade --fade-color transparent

# Loop with pingpong (forward + backward)
python cli.py loop input.webm output.webm --method pingpong

# Auto-detect best loop method
python cli.py loop input.webm output.webm --method auto

# Analyze video to find best method (no processing)
python cli.py loop input.webm output.webm --method auto --analyze-only

# Quick loop test with lower threshold
python cli.py loop input.webm output.webm --scan-frames 30 --match-threshold 40
```

## 📁 Project Structure

```
frame/
├── cli.py              # Entry point
├── core/               # Pipeline executor
│   ├── __init__.py
│   └── bg_removal.py   # Core library for background removal
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
python cli.py fps-boost test_input.mp4 test_output.mp4 --to 60
```

## 📄 License

[MIT](LICENSE)
