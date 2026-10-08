# FramerCore

Elixir/OTP orchestration for Framer. It splits a video edit into frame-range
chunks and farms those chunks out to parallel workers. The operation layer is
the working Python/OpenCV core (`../..`, `framer_worker.py`) reached through a
Port; there are no Rust NIFs and the BEAM never handles pixel data.

See [`docs/elixir-python-ports.md`](../../../docs/elixir-python-ports.md) for the
Port contract, the operation list and the remote/distribution seam.

## Architecture

```
FramerCore.Supervisor
  ├── FramerCore.PlayerRegistry      # player id -> pid
  ├── FramerCore.PlayerSupervisor    # DynamicSupervisor of players
  ├── FramerCore.PlayerPool          # owns how many players exist
  └── FramerCore.Orchestrator        # chunk queue + assignments
```

- `FramerCore.Orchestrator` — single-job chunk queue. A chunk that exhausts its
  retries is marked failed and fails the job; it is never counted as success.
- `FramerCore.Player` — owns one persistent `FramerCore.PortWorker` and runs one
  chunk at a time in a `Task`.
- `FramerCore.PortWorker` — owns the Python OS process and speaks the
  length-prefixed JSON Port protocol.
- `FramerCore.Dispatch` — where a chunk runs: `:local` today, `:remote` is the
  documented seam.
- `FramerCore.Operations` — one-off `merge`/`info` calls through the same Port.

## Setup

```bash
# Python operation layer (from the repository root)
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Elixir
cd framer
mix deps.get
mix test
```

## Usage

```bash
mix run -e 'FramerCore.CLI.main(["remove-bg", "in.mp4", "out.webm", "--color", "0,255,0"])'
mix run -e 'FramerCore.CLI.main(["fps-boost", "in.mp4", "out.mp4", "--to", "60", "--workers", "4"])'
mix run -e 'FramerCore.CLI.main(["loop", "in.mp4", "out.mp4", "--method", "pingpong"])'
mix run -e 'FramerCore.CLI.main(["info", "in.mp4"])'
```

`framer_web` exposes a JSON status/submit surface over the orchestrator at
`GET /api/status`, `GET /api/jobs/:id` and `POST /api/jobs`, plus the rig/bones
LiveView editor at `/editor` (see [`docs/rig-editor.md`](../../../docs/rig-editor.md)).
