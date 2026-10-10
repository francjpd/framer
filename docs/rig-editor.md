# Framer rig editor (LiveView)

The rig/bones animation editor lives inside `framer_web` at `/editor`. It is a
three-pane Phoenix LiveView shell that builds a versioned `framer.rig`
document, previews it on the client, and drives the engine's `deform`
operation for the final render and export.

```
┌───────────────────────────────────────────────────────────────┐
│ header: title · shortcut hint · undo · save                    │
├──────────────┬────────────────────────────────────────────────┤
│ Workflow     │ centre viewport                                 │
│  step guide  │  toolbar: Mesh · Labels · proxy badge           │
│ Media        │  source still + control mesh + bones            │
│  upload      │  client-side WebGL2 / canvas LBS preview        │
│  projects    │                                                 │
│ Tools        │                                                 │
│ Hierarchy    │                                                 │
│ Properties   │                                                 │
│ Bind         │                                                 │
├──────────────┴────────────────────────────────────────────────┤
│ timeline: ruler · transport · keyframe rows · value/velocity  │
│ graph · render/export                                          │
└───────────────────────────────────────────────────────────────┘
```

The BEAM never sees pixel data. The editor sends the engine a still path, a rig
path, a frame range and JSON options - exactly the existing Port contract.

## Layout and tools

* **Left panel (guide + media + tool + inspector).** Modelled on the familiar
  left-hand panel of Premiere Pro / Resolve / Final Cut / Shotcut:
  * **Workflow** - the five-step guide (`#step-guide`), see below.
  * **Media** - the still-image upload and the list of saved projects. Each
    project row carries a `×` remove control that reveals an inline
    confirm/cancel pair before deleting the project's directory; removing the
    rig currently open resets the editor to its empty state.
  * **Tools** - the two first-slice tools, **Bones** and **Pose**.
  * **Hierarchy** - the bone list as an indented tree (children under their
    parent), with selection and delete.
  * **Properties** - the selected bone's **radius**, **falloff** and **parent**.
    The editor auto-assigns the radius when the bone is created; the slider
    then adjusts it.
  * **Bind** - the global bind **power** / **radius scale** and `Auto-bind
    mesh`, which rebuilds the control mesh and per-vertex weights.
* **Centre viewport.** A `phx-hook="LbsPreview"` element with a small toolbar:
  **Mesh** (toggle the wireframe) and **Labels** (toggle bone names), plus a
  `proxy preview` badge. It renders the source still, the control mesh and the
  bones, and handles all pointer interaction locally. The selected bone also
  carries two call-to-action handles: a **move** disc beside its midpoint
  (translate) and a **rotate** ring just beyond its tail (rotate about the
  head), so posing no longer needs a precise grab of a thin joint. The cursor
  reflects what is under the pointer - a grab cursor over a handle or the bone
  body, a select cursor over a joint, and a crosshair (Bones) or default (Pose)
  cursor over empty canvas:
  * **Bones tool** - drag empty canvas to create a bone (`head → tail`); drag a
    joint to move it; drag the body to translate it; dropping near another
    bone's tip parents to it (chains). The move handle translates the bone and
    the rotate handle moves its tail. Structural edits are pushed to LiveView
    on pointer-up and persisted.
  * **Pose tool** - drag a joint to rotate about the bone's rest head, drag the
    body to translate. The move handle translates and the rotate handle rotates
    the pending pose. The pose stays local until **Record keyframe** writes it
    into `keyframes[playhead]`. Recording with nothing posed does not mint an
    empty keyframe - it shows a status hint instead, and stepping the playhead
    with an un-recorded pose hints "Pose not recorded" rather than discarding it
    silently. The pose-pending badge stays as the persistent indicator.
* **Timeline (bottom).** A frame ruler, a transport group (jump to
  start/end, step, play/pause, loop), record/delete keyframe, the playhead
  readout, and `Render frame` / `Export`. The track has two keyframe rows - one
  for every keyframe and one for the selected bone. Below it sits the
  **value/velocity graph** for the selected bone (rot / tx / ty): the solid
  line is the interpolated value across the range, the dashed line its numeric
  derivative in units per second, with the playhead and keyframe points marked.
* **Keyboard shortcuts.** Space play/pause, `K` record keyframe, `←`/`→` step
  one frame, `Home`/`End` jump to the range ends, `Cmd`/`Ctrl+Z` undo. They are
  ignored while a form control has focus.

These are refinements of the existing shell, not a new application: the rig
JSON contract, the fixed-point LBS preview and the `deform` render/export path
are unchanged. Two ideas from the FilmCraft study were deliberately left out
because they are redesigns rather than polish - the single agent-facing
command/catalog/MCP surface (already scoped as a separate future task) and a
multi-track NLE timeline with trim algebra. Per-property (rot/tx/ty) keying
would also need a rig-schema change, so the slice still keys the whole pose.

## Workflow guide

The left palette opens with a five-step workflow guide (`#step-guide`): upload
the still, create the skeleton, bind the mesh, pose and record keyframes,
render/export. It is a pure render of the rig's real state - the current step
is derived from the loaded document (no rig -> step 1, no bones -> step 2,
unbound mesh -> step 3, no keyframes -> step 4, otherwise step 5), completed
steps carry a check mark and the current step is highlighted. While a rig is
loaded the viewport overlays a `pointer-events-none` hint naming the next
step. The guide never gates the editor: every tool and control stays enabled
in any order, and re-binding after posing keeps the recorded keyframes.

## Preview vs final render

One fixed-point linear-blend-skinning implementation, two consumers:

* **Interactive preview** is client side, in
  `assets/js/lbs.mjs` (`computeDenseWeights`, `evaluateBones`,
  `computeBackwardMap`, `remapBilinear`) - the same math as `core/deform.py`.
  A WebGL2 fragment shader resamples the backward map; when WebGL2 is
  unavailable - or its context is lost - the hook falls back to a 2D canvas
  (swapping in a fresh element, then re-initialising WebGL2 when the context
  is restored), and it re-measures the viewport on element resize (a
  `ResizeObserver` catches element-only resizes a window `resize` never sees,
  such as a pane growing inside the three-pane shell or a tiled WM narrowing
  the page), window resize (which re-backs the overlay at a changed
  `devicePixelRatio`), and fullscreen change. The preview runs at a proxy
  resolution and is deliberately labelled
  a proxy. A rig with no bones yet
  (a freshly loaded still) previews the source unchanged: `skinningFields`
  falls back to the identity field, whereas the engine rejects an empty bone
  list outright.
* **Final render** is the engine's `deform` operation. `Render frame` runs a
  single-frame `deform` (`start_frame == end_frame`, image output) through a
  throwaway Port worker; `Export` submits a chunked job to the existing
  `FramerCore.Orchestrator` and merges the chunks.

The two are kept honest by a golden-frame parity test,
`tests/test_preview_parity.py`, which renders the deterministic scene from
`tests/deform_scene.py` with the Python renderer and with `lbs.mjs` under Node
and compares the dense weights, the rendered pixels and the interpolated poses.
It skips when Node is absent; the Python golden test (`tests/test_golden_deform.py`)
still covers the authoritative render. The server-side timeline value/velocity
graph interpolates poses with `FramerWeb.Rig.interpolate_pose/3`, which mirrors
`core.deform.interpolate_keyframes` and `lbs.mjs` `interpolatePoses`; an Elixir
test (`framer/apps/framer_web/test/framer_web/rig_test.exs`) keeps it tied to
`lbs.mjs` so it cannot drift from the browser preview.

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

## Connections

Every `/api/rigs*` endpoint above serves user content and is gated by the
host-approved connection contract: the running app mints a pairing id at
startup, a client presents it to `POST /api/connect` (which only creates a
*pending* request), and the host operator approves it on `/connections` before
any content is served. The host operator's own browser is authorized
automatically. See [`connection-trust-model.md`](connection-trust-model.md).

## Running

First install both toolchains (from the repository root):

```bash
uv sync

cd framer
mix deps.get
```

Then start the editor:

```bash
cd framer
mix phx.server
# then open http://localhost:4000/editor
```

Upload a still, switch to the Bones tool and draw 2-4 bones, press
`Auto-bind mesh`, pose with the Pose tool and `Record keyframe`, then
`Render frame` or `Export`.

## Tests

```bash
cd framer && mix test                      # unit + LiveView + editor e2e
uv run python -m pytest tests/ -q          # engine + preview parity
```

The editor end-to-end path (`framer_web/test/.../rig_e2e_test.exs`) uploads a
still, binds a rig, renders a frame and exports a video through the JSON
surface, then decodes the merged WebM and asserts the deformation on pixels -
the same shape as the engine's `port_integration_test.exs`.

The browser proof suite (`browser_preview_test.exs`, tagged
`:requires_chromium`) drives the real Chromium through
`tests/browser/editor_runner.mjs` (playwright-core, no browser download) and
asserts preview pixels on saved `#viewport` screenshots - the browser-level
regressions for the slice-1 blank-preview defect and, since slice 4, for
viewport resize, WebGL context loss/recovery and fullscreen re-measure. It also
covers click precision (a bone landing where clicked at non-1 DPR and after a
resize) and the call-to-action handles (the move handle posing rather than
mutating rest geometry, the rotate handle dragging the tail without a start
jump). It excludes itself when
Chromium, Node or the built editor assets are missing, so to run it locally,
install the harness and build the assets first:

```bash
(cd tests/browser && npm ci)
(cd framer && MIX_ENV=dev mix assets.setup)
(cd framer && MIX_ENV=dev mix assets.build)
cd framer && mix test
```
