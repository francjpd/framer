# The agent-facing command surface (`framer`)

framer is a set of file-in/file-out video operations. An agent that wants to
use them should not have to read prose, so framer ships one command that can
describe itself: **the catalog plus the CLI already answer the discoverability
requirement, and no MCP server is built on top of it** (see
[Why no MCP server](#why-no-mcp-server) below).

## The command

`framer` is an escript built from the Elixir umbrella. It is a standalone
binary over the BEAM orchestrator and the Python Port - not a wrapper over
`cli.py` - so every operation runs the chunked, parallel path with progress,
which is the default rather than a special invocation.

```bash
# Build (from this app's directory; the binary lands in the repo at ./framer)
cd framer/apps/framer_core
mix escript.build

# Run
./framer remove-bg in.mp4 out.webm --color 0,255,0
./framer deform still.png out.webm --rig rig.json
./framer loop in.mp4 out.mp4 --method pingpong
./framer fps-boost in.mp4 out.mp4 --to 60
```

The build bakes in `framer/config/config.exs`, so the worker path
(`framer_worker.py`) and the Python interpreter come along with it. Point it
somewhere else with the environment variables the Port layer already honours:
`FRAMER_PYTHON`, `FRAMER_WORKERS`. Build it in `:dev` or `:test`, never `:prod`
- `config/runtime.exs` demands `DATABASE_URL` for `framer_web` in `:prod`, which
this command does not use.

## stdout, stderr and exit codes

The streams carry a contract, so a caller never has to scrape a log:

| stream | content |
| --- | --- |
| `stdout` | the machine contract: JSON from `list --json` / `describe --json`, the output path of a successful operation |
| `stderr` | progress, diagnostics, human help |
| exit code | `0` on success, `1` on any failure |

Application logging is redirected to `stderr` for the same reason
(`config :logger, :default_handler` in `framer/config/config.exs`), so the
orchestrator's chunk progress keeps streaming there exactly as it always has.

The command also starts as little as possible: the escript is configured with
`app: nil`, and `FramerCore.ensure_started!/0` boots the orchestrator, the
player pool and their Python workers only for a command that needs them. `framer
list`, `framer describe` and `framer --version` answer from the catalog in
memory, so they are fast and need no Python interpreter on the machine.

## The catalog

`FramerCore.Catalog` is the **single definition** of every operation: its name,
a one-line summary and a longer description, the positional arguments it takes,
its options (flag, short flag, type, default, choices, help), what it produces
and how the frame count is resolved. `framer list` / `framer describe` print
that table, and `FramerCore.JobRunner` drives the very same table, so the human
help and the machine-readable JSON **cannot drift apart**.

```bash
framer list                       # human-readable overview
framer list --json                # the whole catalog
framer describe remove-bg         # one operation's full contract
framer describe remove-bg --json  # the same, machine-readable
framer remove-bg --help           # same as describe remove-bg
```

`framer list --json`:

```json
{
  "name": "framer",
  "version": "0.1.0",
  "operations": [
    {
      "name": "remove-bg",
      "summary": "Remove the background from a video, writing an alpha channel",
      "description": "...",
      "usage": "framer remove-bg <input> <output> [options]",
      "args": [
        {"name": "input", "help": "video to key, for example in.mp4", "required": true},
        {"name": "output", "help": "destination, .webm or .mov to keep the alpha", "required": true}
      ],
      "produces": "an alpha-channel video (.webm or .mov) with the background keyed out",
      "options": [
        {
          "name": "color",
          "flag": "--color",
          "short": "-c",
          "arg": "COLOR",
          "type": "color",
          "default": null,
          "required": false,
          "choices": null,
          "help": "Background colour as #RRGGBB or B,G,R (default: detected from the clip)"
        }
      ]
    }
  ]
}
```

`framer describe <operation> --json` emits exactly the matching array element, so
a client parses one document either way. Options accept `--flag value`,
`--flag=value` and the documented short flags; a boolean flag is `true` on its
own or takes an explicit `--flag true|false`. Options that default to `nil` are
absent from the parsed invocation, which is how "detect it for me" is spelled.

`--workers` is a property of the orchestrator rather than of an operation, so
every operation accepts it: it sizes the player pool the job is chunked across.

## What the catalog covers

The catalog lists what the `framer` command can run: the operations the Python
Port worker implements (`framer_worker.py`'s `_OPERATIONS`). That is
`remove-bg`, `fps-boost`, `loop` and `deform`, plus the internal `info` and
`merge` Port operations that framer drives on a caller's behalf.

The standalone Python CLI operations (`resize`, `trim`, `export`, `recolor`,
`glow`, `outline`) are **not** catalogued, because the Port worker has no
handler for them: listing them would advertise a command that fails. They stay
where they are - `python cli.py resize ...` - and the moment a worker handler
exists for one of them, adding a catalog entry is the whole change.

## Worker-internal tunables

Two knobs the worker reads are deliberately not catalogued, because neither is
a flag an agent can set: the Python CLI never exposed them either, so adding
them would widen the command surface beyond what the catalog is meant to own.
They are fixed worker defaults, not options.

| operation | key | default | meaning |
| --- | --- | --- | --- |
| `remove-bg` | `motion_threshold` | `15` | motion-detection threshold used when `--method motion` or `--method combined`; the fixed complement to the exposed `--motion-frames` |
| `deform` | `still` | auto | whether the source is treated as a still image; unset, the worker decides from the input extension (an image path is a still, a video path is read as its first frame) |

## Keeping it honest

- `FramerCore.CatalogTest` compares the catalog against the operations the
  worker actually registers, so **a new operation without a catalog entry fails
  the suite**, and so does a catalog entry the worker cannot run.
- `FramerCore.ArgsTest` checks the parser against the catalog, so an invocation
  is only valid if the catalog describes it.
- `FramerCore.EscriptTest` builds the escript with `mix escript.build` and runs
  real operations (`remove-bg`, `deform`) through it, asserting the output file,
  the exit code and the clean stdout contract.
- The CI workflow builds the escript and walks the whole catalog, so a broken
  build path fails without needing any media work.

## Why no MCP server

The requirement was discovery: an agent should be able to enumerate what framer
can do and call it, instead of reading a README. `framer list --json` plus
`framer describe <op> --json` is that enumeration, and `framer <op>` is that
call, over a process boundary every agent harness already has. An MCP server
would add a third surface (CLI, web API, MCP) that must be kept in sync with the
same catalog, without adding a capability framer's operations lack: they are
deterministic file-in/file-out jobs with no interactive session to expose.

FilmCraft's MCP surface earns its keep mostly with tools a command cannot offer
- `ui_click`, `ui_drag`, `ui_screenshot` against a live window, plus streaming
progress for a long render. Framer has no GUI to drive, and progress already
streams on `stderr`. The honest follow-up, if the need appears, is a thin MCP
shim that reads `FramerCore.Catalog` for its tool list - a day of work because
the catalog exists - rather than a second definition of the operations.

Where an MCP-like surface would genuinely add something today is job lifecycle:
`POST /api/jobs` + `GET /api/jobs/:id` already gives submit-and-poll for the
editor, and the same is available to an agent through the CLI. If framer grows
long-lived, cancellable, inspectable server-side jobs, that is the moment to
revisit the transport question - with the catalog still as the single source.

## Replacing the old invocation

`FramerCore.CLI.main/1` is the same entry point it always was, so the historical
invocation still works and the `mix remove_bg` / `mix loop_op` / `mix fps_boost`
tasks are thin front-ends over it:

```bash
mix run -e 'FramerCore.CLI.main(["deform", "still.png", "out.webm", "--rig", "rig.json"])'
```

New callers - people and agents - should use the escript: one command, one
discoverable catalog, no `mix` in the loop.
