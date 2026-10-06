# framer

framer is a video processing tool: it removes a video's background, raises its frame rate, and builds seamless loops. Operations are small and chainable, and jobs run in parallel for speed.

Under the hood, a Python/OpenCV core does the pixels and an Elixir layer schedules the work across cores.

## Architecture

```
CLI / Phoenix / web
      │  submit_job(operation, input, output, total_frames, fps, options)
      ▼
FramerCore.Orchestrator          # splits the edit into frame-range chunks
      │
      ▼
FramerCore.PlayerPool            # N persistent players, one Python process each
      │
      ▼
FramerCore.Player ──► FramerCore.PortWorker ──► framer_worker.py
 (GenServer; runs one        owns one Python OS       length-prefixed JSON
  chunk at a time in a Task) process                   over stdin/stdout
                                                            │
                                                            ▼
                                                     core/ + ops/
                                                   (OpenCV / FFmpeg)
```

- **Chunked, parallel jobs** - the orchestrator splits a job into frame-range
  chunks and hands them to a pool of persistent players. Each player runs one
  chunk at a time and keeps one long-lived Python process for the life of the
  pool, so a crash in OpenCV/FFmpeg kills a worker process, never the BEAM.
- **No pixel data crosses the BEAM** - a request is only file paths, a frame
  range and a JSON options object. `framer_worker.py` reads its input chunk,
  runs the Python core and writes its output chunk file.
- **Distributed-ready seam** - `FramerCore.Dispatch` is the single place that
  decides *where* a chunk runs. The local path is implemented and tested;
  `:remote` hands the same request to a `FramerCore.PortWorker` on another node
  through `:erpc.call/5`. Optional remote players are configured with
  `:remote_players`, and the system runs happily standalone with no cluster.

See [`docs/elixir-python-ports.md`](docs/elixir-python-ports.md) for the full
Port contract, request lifecycle, configuration keys and distribution seam.

## Operations

Every operation reachable over the Port uses the same contract: paths, a frame
range and JSON options. Operations that write alpha (`remove-bg`, `deform`)
must target an alpha-capable container (`.webm` or `.mov`); `.mp4` drops the
alpha plane. `export` is standalone-only: it runs through the Python CLI and is
not dispatched by the orchestrator.

| Operation | Runs | Notes |
| --- | --- | --- |
| `remove-bg` | chunked, parallel | Per-frame background removal with an alpha channel. Color / motion detection, auto color ranges, mask refinement. |
| `fps-boost` | chunked, parallel | Frame-rate interpolation with FFmpeg's `minterpolate`. |
| `deform` | chunked, parallel | Rig/bones puppet-warp of a still image over a timeline; BGRA output. |
| `loop` | whole file | Seamless infinite loops; reads the whole file, so it is always one chunk. |
| `merge` | finishing step | FFmpeg concat of the finished chunks into the requested output. |
| `info` | one-off | `ffprobe` resolution, FPS and frame count. |
| `export` | Python CLI | Web-optimized `.webm` / `.mp4` / `.gif` output, alongside the other standalone Python CLI operations (`resize`, `trim`, `recolor`, `glow`, `outline`). |

### `deform`
Rig/bones puppet-warp of a still image over a timeline, rendered frame by frame
and exported to an alpha-capable video. The rig is a versioned JSON document;
see [`docs/rig-schema-v1.md`](docs/rig-schema-v1.md) for the schema and the
Port request contract.

```bash
# Render one frame (start == end) to PNG
python cli.py deform still.png frame.png --rig rig.json --start-frame 12 --end-frame 12

# Render the whole rig timeline to a video
python cli.py deform still.png out.webm --rig rig.json
```

**Options:**
- `--rig` or `-r` - Path to a `framer.rig` JSON document (required)
- `--start-frame` / `--end-frame` - Frame range (defaults to `rig.duration.frames`)
- `--fps` - Output fps (default: `rig.duration.fps`)
- `--iterations` or `-i` - Fixed-point inversion iterations (default: 5)
- `--weights` - Optional dense-weight `.npz` cache path
- `--radius-scale` - Scale every bone influence radius

---

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

## Front end

`framer_web` is a Phoenix application that sits on the orchestrator. Today it
exposes a minimal JSON status/submit surface (`GET /api/status`,
`GET /api/jobs/:id`, `POST /api/jobs`) and a placeholder `/editor` LiveView.

The planned **Phoenix LiveView editor** is a frame-by-frame UI for the
bones/puppet-warp animation: viewport over the source still and rig mesh,
a timeline of keyframes over the rig's frame range, and export that submits a
`deform` job through the same job API. The engine half already ships - the rig
schema and the chunked `deform` export run entirely through the Port contract -
while the editor itself is a follow-up task behind the `/editor` route shell.

## 📁 Repository layout

```
framer/
├── core/               # Python/OpenCV operation core
│   ├── bg_removal.py   # Background removal primitives
│   ├── mask_refinement.py, color_ranges.py, motion_detection.py
│   ├── deform.py       # Rig/bones LBS math
│   └── video.py, parallel.py, gpu*.py
├── ops/                # Python operation implementations
│   ├── remove_bg.py, fps_boost.py, loop.py, deform.py, export.py
│   └── resize.py, trim.py, recolor.py, glow.py, outline.py
├── cli.py              # Standalone Python CLI over ops/
├── framer_worker.py    # The Port worker the BEAM spawns
├── framer/             # Elixir/OTP umbrella
│   ├── apps/framer_core/   # Orchestrator, players, Port worker, CLI
│   └── apps/framer_web/    # Phoenix API + /editor LiveView shell
├── docs/               # Port contract, rig schema, design plans
└── tests/              # Python tests for the operation core
```

## 🚀 Quick Start

The Elixir orchestrator drives the Python core, so set up both halves.

**1. Python operation layer** (from the repository root):

```bash
# venv (standard)
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# or conda
conda create -n framer python=3.10
conda activate framer
pip install -r requirements.txt
```

**2. Elixir orchestration:**

```bash
cd framer
mix deps.get
mix test
```

**3. Process a video through the orchestrator** (from `framer/`):

```bash
mix run -e 'FramerCore.CLI.main(["info", "input.mp4"])'
mix run -e 'FramerCore.CLI.main(["remove-bg", "input.mp4", "output.webm", "--color", "0,255,0"])'
mix run -e 'FramerCore.CLI.main(["fps-boost", "input.mp4", "output.mp4", "--to", "60", "--workers", "4"])'
mix run -e 'FramerCore.CLI.main(["loop", "input.mp4", "output.mp4", "--method", "pingpong"])'
mix run -e 'FramerCore.CLI.main(["deform", "still.png", "output.webm", "--rig", "rig.json"])'
```

The same operations are also available directly through the standalone Python
CLI:

```bash
# Boost FPS to 60
python cli.py fps-boost input.mp4 output.mp4 --to 60

# Remove background
python cli.py remove-bg input.mp4 output.webm --tolerance 30

# Use config file for complex operations
python cli.py remove-bg input.mp4 output.webm --config config.json
```

## 🔧 Configuration Files

For complex operations with many options, the Python CLI accepts a JSON config:

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
```

## 🔌 Extending the operation core

Python operations are registered via decorator:

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

- Python 3.9+ and the packages in [`requirements.txt`](requirements.txt)
  (NumPy, OpenCV, Typer, Rich, and PyTorch, which powers GPU acceleration).
- Elixir `~> 1.15` with a matching Erlang/OTP (see
  [`framer/.tool-versions`](framer/.tool-versions)) for the orchestration layer.
- FFmpeg (installed and in PATH).

## 🛠️ Development

```bash
# Python operation core
python -m pytest tests/

# Elixir orchestration (includes the end-to-end Port integration test)
cd framer
mix test
```

`framer/apps/framer_core/test/port_integration_test.exs` generates a small clip
with FFmpeg, drives it through the orchestrator and the Python Port, merges the
chunks and asserts the background is actually transparent.

## 📄 License

MIT
