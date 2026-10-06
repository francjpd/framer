# Framer rig editor (LiveView)

The rig/bones animation editor lives inside `framer_web` at `/editor`. It is a
three-pane Phoenix LiveView shell that builds a versioned `framer.rig`
document, previews it on the client, and drives the engine's `deform`
operation for the final render and export.

```
┌───────────────────────────────────────────────────────────────┐
│ header: project switcher · upload still · undo · save          │
├──────────────┬────────────────────────────────────────────────┤
│ tool palette │ centre viewport                                 │
│ · Bones      │  source still + control mesh + bones            │
│ · Pose       │  client-side WebGL2 / canvas LBS preview        │
│ · properties │                                                 │
│ · bind       │                                                 │
├──────────────┴────────────────────────────────────────────────┤
│ timeline: transport · playhead · keyframe row · render/export  │
└───────────────────────────────────────────────────────────────┘
```

The BEAM never sees pixel data. The editor sends the engine a still path, a rig
path, a frame range and JSON options - exactly the existing Port contract.

## Layout and tools

* **Tool palette (left).** The two first-slice tools, the bone list, the
  selected bone's **radius** and **falloff**, its **parent**, and the global
  bind **power** / **radius scale**. `Auto-bind mesh` rebuilds the control mesh
  and per-vertex weights.
* **Centre viewport.** A `phx-hook="LbsPreview"` element. It renders the source
  still, the control mesh wireframe and the bones, and handles all pointer
  interaction locally:
  * **Bones tool** - drag empty canvas to create a bone (`head → tail`); drag a
    joint to move it; drag the body to translate it; dropping near another
    bone's tip parents to it (chains). Structural edits are pushed to LiveView
    on pointer-up and persisted.
  * **Pose tool** - drag a joint to rotate about the bone's rest head, drag the
    body to translate. The pose stays local until **Record keyframe** writes it
    into `keyframes[playhead]`.
* **Timeline (bottom).** Playhead scrub (a `TimelineScrub` hook), play/pause
  with an fps-driven tick, record/delete keyframe, loop toggle, a keyframe
  marker row, `Render frame` and `Export`.

## Preview vs final render

One fixed-point linear-blend-skinning implementation, two consumers:

* **Interactive preview** is client side, in
  `assets/js/lbs.mjs` (`computeDenseWeights`, `evaluateBones`,
  `computeBackwardMap`, `remapBilinear`) - the same math as `core/deform.py`.
  A WebGL2 fragment shader resamples the backward map; when WebGL2 is
  unavailable the hook falls back to a 2D canvas. The preview runs at a proxy
  resolution and is deliberately labelled a proxy.
* **Final render** is the engine's `deform` operation. `Render frame` runs a
  single-frame `deform` (`start_frame == end_frame`, image output) through a
  throwaway Port worker; `Export` submits a chunked job to the existing
  `FramerCore.Orchestrator` and merges the chunks.

The two are kept honest by a golden-frame parity test,
`tests/test_preview_parity.py`, which renders the deterministic scene from
`tests/deform_scene.py` with the Python renderer and with `lbs.mjs` under Node
and compares the dense weights and the rendered pixels. It skips when Node is
absent; the Python golden test (`tests/test_golden_deform.py`) still covers the
authoritative render.

## Persistence

Filesystem-first, with Ecto/Postgres still disabled. `FramerWeb.RigStore` owns
one directory per project under the projects root (`:framer_web, :projects_dir`,
default `apps/framer_web/priv/projects`):

```
<root>/<rig-id>/
  source.png      # uploaded still
  rig.json        # framer.rig v1 - the engine-facing contract
  output.webm     # merged export, once rendered
```

`rig.json` is the durable artifact; the editor autosaves on every structural
change and `Undo` restores the previous document (up to 40 steps). Rig ids are
opaque and URL-safe, so an `:id` path segment can never escape the root.

## JSON surface

Extends the existing `/api` surface (`FramerWebWeb.RigController`):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/rigs` | list saved rigs |
| `POST` | `/api/rigs` | create from a base64 still or a canvas size |
| `GET` | `/api/rigs/:id` | load a rig document |
| `PUT` | `/api/rigs/:id` | save a rig document |
| `POST` | `/api/rigs/:id/render` | render one full-quality frame (PNG) |
| `POST` | `/api/rigs/:id/export` | submit a chunked `deform` export |
| `GET` | `/api/rigs/:id/source` | the source still |
| `GET` | `/api/rigs/:id/result` | the merged export (download) |

Export progress is polled from the existing `GET /api/jobs/:id`; the server-side
watcher merges the finished chunks and broadcasts completion on the
`rig:<id>` PubSub topic.

## Running

```bash
cd framer
mix deps.get
mix ecto   # not needed - there is no database
mix phx.server
# then open http://localhost:4000/editor
```

Upload a still, switch to the Bones tool and draw 2-4 bones, press
`Auto-bind mesh`, pose with the Pose tool and `Record keyframe`, then
`Render frame` or `Export`.

## Tests

```bash
cd framer && mix test                      # unit + LiveView + editor e2e
.venv/bin/python -m pytest tests/ -q       # engine + preview parity
```

The editor end-to-end path (`framer_web/test/.../rig_e2e_test.exs`) uploads a
still, binds a rig, renders a frame and exports a video through the JSON
surface, then decodes the merged WebM and asserts the deformation on pixels -
the same shape as the engine's `port_integration_test.exs`.
