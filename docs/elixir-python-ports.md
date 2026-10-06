# Framer: the Elixir ↔ Python Port bridge

This document describes how the Elixir/OTP orchestrator drives the working
Python/OpenCV operation layer, and where remote/distributed workers plug in.

The Elixir actor model (chunk queue, parallel players, progress, supervision)
comes from the earlier POC, but the Rust NIF / FFmpeg-filter operation layer was
replaced with a **Port** to the Python core (`core/`, `ops/`, `cli.py`).

## Why Ports

- A crash in OpenCV/FFmpeg kills one worker OS process, not the BEAM.
- The BEAM never links native code, so a long encode cannot block a scheduler.
- The exact same request can be sent to a process on another machine, which is
  the whole point (split a large edit and distribute it later).

## The contract

**The BEAM never passes pixel data.** A request is only file paths, a frame
range and JSON options. The Python worker reads its input chunk and writes its
output chunk file.

```jsonc
// Request (Elixir -> Python)
{
  "id":          "e2f1...",        // correlation id, echoed back
  "op":          "remove-bg",      // remove-bg | fps-boost | loop | merge | info
  "input":       "/abs/input.mp4", // source file (nil for merge)
  "output":      "/abs/chunk.webm",// destination chunk file
  "start_frame": 0,                // inclusive
  "end_frame":   49,               // inclusive
  "fps":         30.0,             // source frame rate
  "options":     { "color": "0,255,0", "tolerance": 40 }
}

// Response (Python -> Elixir)
{ "id": "e2f1...", "status": "ok",    "output": "/abs/chunk.webm", "frames": 50 }
{ "id": "e2f1...", "status": "error", "error": "..." }
```

Framing is a **4-byte big-endian length prefix** followed by the UTF-8 JSON
payload (`Port.open(..., packet: 4)` on the Elixir side; `struct.pack(">I", ...)`
on the Python side). The worker redirects all of its own stdout to stderr, so
OpenCV/FFmpeg chatter can never corrupt the protocol stream.

### Request lifecycle

```
CLI / web
   │  submit_job(operation, input, output, total_frames, fps, options)
   ▼
FramerCore.Orchestrator ── builds chunks (operation, paths, range, options)
   │  Player.process_chunk(player_id, chunk)
   ▼
FramerCore.Player (one per worker)            ← GenServer, registry keyed
   │  Dispatch.execute(%{kind: :local, worker: port_worker}, Chunk.to_request(chunk))
   ▼
FramerCore.PortWorker                    ← owns one Python OS process
   │  Port.command(port, json)
   ▼
framer_worker.py  ── reads input chunk, runs the Python core, writes output chunk
```

`FramerCore.Player` runs the blocking `PortWorker.run/3` inside a `Task` so its
mailbox stays responsive. Each player keeps one Python process for the lifetime
of the pool: **one worker process per player, not one per frame**. A completed
chunk triggers the player's prefetch request; the orchestrator hands out the
next queued chunk.

### Operations

| `op`        | Reuses | Notes |
| ----------- | ------ | ----- |
| `remove-bg` | `core/bg_removal.py` (`_remove_bg_frame_processor`), `core/color_ranges.py`, `core/mask_refinement.py`, `core/motion_detection.py` | per-frame keying, chunkable; writes BGRA chunks |
| `fps-boost` | `ffmpeg` (same filter choices as `ops/fps_boost.py`) | interpolates a frame range, chunkable |
| `loop`      | `ops/loop.py` (`create_loop`) | whole-file operation, always one chunk |
| `deform`    | `core/deform.py` (LBS math), `ops/deform.py` (render/loop) | rig/bones puppet warp of a still image, chunkable; writes BGRA chunks |
| `merge`     | `ffmpeg` concat | concatenates finished chunks into the final output |
| `info`      | `ffprobe` | resolves width/height/fps/frame count |

Colour auto-detection, motion masks and refinement are all performed inside the
Python worker, so the BEAM only carries the resolved options and the paths.

### Still-image input (`deform`)

A still image has no frame count, so `deform` settles the convention in the op
itself instead of changing the orchestrator: it reads the image once
(`cv2.imread`, BGRA) and **loops it** over the requested
`[start_frame, end_frame]`. The caller supplies `total_frames` and `fps` from
the rig document's `duration` (the CLI does this; `submit_job` only requires
`total_frames > 0`). The rig travels as a path in `options.rig` and the rig
schema is documented in `docs/rig-schema-v1.md`; no pixels cross the Port.

### Known limitations

- `remove-bg` needs an alpha-capable container (`.webm` or `.mov`); `.mp4`
  drops the alpha plane. When verifying output, decode with `-c:v libvpx-vp9`:
  FFmpeg's native VP9 decoder silently discards alpha.
- `fps-boost` interpolates each chunk independently. Chunks never duplicate
  boundary frames (the old 2-frame overlap bug), but `minterpolate` does not
  emit exactly `target_fps × duration` frames - the same behaviour as the
  single-pass Python baseline.
- `loop` is a whole-file operation (`ops/loop.py` reads frames with OpenCV) and
  therefore does not preserve an input alpha channel.
- `deform` writes BGRA chunks, so its output must be `.webm` or `.mov` when the
  source has transparency; `.mp4` drops the alpha plane and the op rejects it
  with an explicit error. Decoding a VP9 `.webm` for verification still needs
  `-c:v libvpx-vp9`.

## Distribution seam

`FramerCore.Dispatch` is the single place that decides **where** a chunk runs:

```elixir
# local (implemented and tested)
Dispatch.execute(%{kind: :local, worker: port_worker_pid}, request)

# remote (seam)
Dispatch.execute(%{kind: :remote, node: :"worker@host", worker: worker_ref}, request)
```

The remote branch uses `:erpc.call/5` to invoke `FramerCore.PortWorker.run/3`
on another node. A remote worker reference should be a **registered name**
(for example `{:global, {:framer_worker, "player-1"}}`) rather than a raw pid, so
the target survives worker restarts on the remote node.

`FramerCore.Player` already supports `backend: :remote` with a dispatch target,
and `FramerCore.PlayerPool` reads the optional
`config :framer_core, :remote_players` list and starts remote-backed players
alongside the local ones. The local path is fully implemented and the whole
system runs happily with no cluster; adding nodes is configuration plus a node
that runs the same OTP release and exposes a `FramerCore.PortWorker`.

A chunk carries everything it needs (operation, paths, range, options), so
remote assignment adds no new data transfer and the BEAM still never touches
pixels.

### Configuration

| Key | Default | Purpose |
| --- | ------- | ------- |
| `:python_executable` | `.venv/bin/python` if present, else `python3` | Python interpreter (override with `FRAMER_PYTHON`) |
| `:python_worker` | `<repo>/framer_worker.py` | Port worker script |
| `:worker_count` | `min(6, max(2, schedulers-2))` (override with `FRAMER_WORKERS`) | number of local Python players |
| `:remote_players` | `[]` | list of `{id, {node, worker_ref}}` remote players |

## Running and validating

```bash
# Python side (operation layer)
python3 -m venv .venv && .venv/bin/pip install opencv-python-headless numpy

# Elixir side (orchestration)
cd framer
mix deps.get
mix test                      # includes the real end-to-end Port integration test

# CLI
mix run -e 'FramerCore.CLI.main(["remove-bg", "in.mp4", "out.webm", "--color", "0,255,0"])'
mix run -e 'FramerCore.CLI.main(["fps-boost", "in.mp4", "out.mp4", "--to", "60", "--workers", "4"])'
mix run -e 'FramerCore.CLI.main(["loop", "in.mp4", "out.mp4", "--method", "pingpong"])'
mix run -e 'FramerCore.CLI.main(["deform", "still.png", "out.webm", "--rig", "rig.json"])'
```

`framer/apps/framer_core/test/port_integration_test.exs` generates a small clip
with FFmpeg, drives it through the orchestrator and the Python Port, merges the
chunks and asserts the background is actually transparent (decoding with
`libvpx-vp9`, because FFmpeg's native VP9 decoder drops the alpha plane).
