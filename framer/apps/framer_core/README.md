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
- `FramerCore.Catalog` — the single definition of every operation the `framer`
  command exposes: arguments, options, defaults, what each one produces.
- `FramerCore.Args` — the generic parser that turns a command line into an
  invocation of a catalog entry.
- `FramerCore.JobRunner` — resolves the frame count, submits to the orchestrator,
  reports progress and merges the finished chunks.
- `FramerCore.CLI` — the `framer` surface itself (and the escript's `:main_module`).

## Setup

```bash
# Python operation layer (from the repository root)
uv sync

# Elixir
cd framer
mix deps.get
mix test
```

## The `framer` command

```bash
# Build the escript (the binary lands in this app's directory)
mix escript.build

# Describe yourself
./framer list [--json]
./framer describe remove-bg [--json]

# Run
./framer remove-bg in.mp4 out.webm --color 0,255,0
./framer fps-boost in.mp4 out.mp4 --to 60 --workers 4
./framer loop in.mp4 out.mp4 --method pingpong
./framer deform still.png out.webm --rig rig.json
./framer info in.mp4
```

`FramerCore.Catalog` is the single definition those commands render from and the
runner drives from, so the help and the JSON catalog cannot drift. See
[`docs/agent-command-surface.md`](../../../docs/agent-command-surface.md) for the
JSON contract, the build path and why there is no MCP surface on top of it.

The historical invocation still works - `main/1` is unchanged, and
`mix remove_bg` / `mix loop_op` / `mix fps_boost` are front-ends over it:

```bash
mix run -e 'FramerCore.CLI.main(["remove-bg", "in.mp4", "out.webm", "--color", "0,255,0"])'
```

`framer_web` exposes a JSON status/submit surface over the orchestrator at
`GET /api/status`, `GET /api/jobs/:id` and `POST /api/jobs`, plus the rig/bones
LiveView editor at `/editor` (see [`docs/rig-editor.md`](../../../docs/rig-editor.md)).
