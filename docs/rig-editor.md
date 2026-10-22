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
│  step guide  │  toolbar: Mesh · Labels · zoom -/+ · Fit · badge│
│ Media        │  source still + control mesh + bones            │
│  upload      │  client-side WebGL2 / canvas LBS preview        │
│  projects    │                                                 │
│ Tools        │                                                 │
│ Hierarchy    │                                                 │
│ Properties   │                                                 │
│ Bind         │                                                 │
│ Layers       │                                                 │
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
    parent), with selection and delete. Rows show each bone's readable name
    (falling back to its `id`), so a renamed skeleton reads as anatomy.
  * **Properties** - the selected bone's **name**, **radius**, **falloff** and
    **parent**. The name field is an inline rename: it is validated as a
    non-empty string, persisted with the rest of the document and shown in the
    hierarchy, the selected-bone label and behind the viewport **Labels**
    toggle. The bone `id` is unchanged by a rename - it stays the key for
    parenting and for the per-bone keyframe pose map. The editor auto-assigns
    the radius when the bone is created; the slider then adjusts it.
  * **Bind** - the global bind **power** / **radius scale** and `Auto-bind
    mesh`, which rebuilds the control mesh and per-vertex weights.
  * **Layers panel** - lists the project's layers (source still, character layer,
    and background layer) with their active state and file paths. Each layer provides
    actions to **Keep**, **Remove**, or **Change** (upload replacement image). Removing
    the background layer drops the background entirely, leaving only the character
    layer rendered and exported with transparency (the no-background outcome). See
    [Character and background layers](#character-and-background-layers).
* **Centre viewport.** A `phx-hook="LbsPreview"` element with a small toolbar:
  **Mesh** (toggle the wireframe), **Labels** (toggle bone names), a **zoom**
  group (**−** / **+** zoom out and in, **Fit** back to the contain-fit) and a
  `proxy preview` badge. It renders the source still, the control mesh and the
  bones, and handles all pointer interaction locally. The view starts as a
  contain-fit of the whole still and **zooms** with the controls or a
  `Ctrl`/`Cmd` + mouse-wheel that zooms toward the pointer; the zoom is bounded
  below by the fit and above by the still's own pixels (1:1), except that a
  still the viewport already shows at 1:1 or larger pins the zoom at the fit.
  The container
  keeps the one pointer-to-image mapping exact at every zoom, so a click still
  places a bone under the pointer with the overlay aligned - panning is not
  implemented (zooming toward the pointer reaches any region) and is left as a
  follow-up. The selected bone also
  carries two call-to-action handles: a **move** disc beside its midpoint
  (translate) and a **rotate** ring just beyond its tail (rotate about the
  head), so posing no longer needs a precise grab of a thin joint. Every bone
  carries a small violet **link dot** behind its head in the Bones tool: drag
  it onto another bone to make that bone this bone's parent - a one-drag
  shortcut for the parent dropdown, with the same cycle refusal. A live dotted
  connector follows the pointer while the drag is in flight, and the dotted
  parent link stays drawn once it lands. On pointer-down the nearest
  affordance wins: a dot claims the grab - and shows the alias cursor - only
  when no nearer handle or bone body exists, so a dot drawn over another
  bone's barrel never steals that bone's grab. The cursor reflects what is
  under the pointer - a grab cursor over a handle or the bone body, a select
  cursor over a joint, an alias cursor over a link dot, and a crosshair
  (Bones) or default (Pose) cursor over empty canvas:
  * **Bones tool** - drag empty canvas to create a bone (`head → tail`); drag a
    joint to move it; drag the body to translate it; dropping near another
    bone's tip parents to it (chains); drag a link dot onto another bone to
    re-parent it. The move handle translates the bone and the rotate handle
    moves its tail. A drag on a placed bone renders live: the bone, its
    joint, its CTA handles and any parent link are drawn where they will
    land on every pointer move, like the create drag's rubber band. The
    drawn bone is also the one that responds: the dropped pose stays on screen
    until the server's rig event carries that same pose, so a second press
    between the pointer-up that commits an edit and that event lands on the
    drawn geometry and its drag on top of that edit, never on the rest the
    server still has stored, and a burst of edits keeps the last dropped pose
    drawn until every edit in it has landed. Structural edits are pushed to
    LiveView on pointer-up and persisted.
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
  ignored while a form control has focus. `Ctrl`/`Cmd` + mouse-wheel zooms the
  viewport toward the pointer (flip the sign to zoom out; **Fit** returns to the
  whole still).

These are refinements of the existing shell, not a new application: the rig
JSON contract, the fixed-point LBS preview and the `deform` render/export path
are unchanged. Two ideas from the FilmCraft study were deliberately left out
because they are redesigns rather than polish - the single agent-facing
command/catalog/MCP surface (already scoped as a separate future task) and a
multi-track NLE timeline with trim algebra. Per-property (rot/tx/ty) keying
would also need a rig-schema change, so the slice still keys the whole pose.

## Action feedback and blocking loader

The editor provides unambiguous visual feedback for every user action:

* **Immediate acknowledgement.** Buttons and forms display a per-action busy
  state via LiveView's built-in `.phx-click-loading`, `.phx-submit-loading`, and
  `.phx-change-loading` classes with reduced opacity, spinning indicator, and
  disabled pointer events so clicks register the moment they land. Actions that
  wait on the server push with `page_loading: true`, so the top bar appears
  immediately and clears when the reply lands.
* **Blocking loader for long waits.** Actions that require background computation
  (such as `Export`, `Render frame`, or character extraction / background removal)
  display a blocking modal overlay (`#blocking-loader` or `#client-blocking-loader`).
  This blocks viewport pointer interactions, timeline scrubbing, and keyboard
  shortcuts, preventing the user from acting on stale state while the engine works.
  * The loader names the exact operation being waited on.
  * For jobs with progress tracking (like `Export`), an honest progress bar and
    percentage readout are shown rather than an indeterminate spinner.
* **Failure visibility.** Failures during background tasks or operations (such as
  render errors, export encoding failures, or attempting rig operations without a
  loaded rig) surface prominently in the `#editor-error` banner with a clear error
  message and dismiss control rather than silently returning to idle.

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
still covers the authoritative render. The same file proves the layering agrees:
it renders the split scene from `tests/layer_scene.py` through the preview with
both layers (as well as character-only with transparency when the background is
removed) and compares against the engine's layered render. The server-side timeline value/velocity
graph interpolates poses with `FramerWeb.Rig.interpolate_pose/3`, which mirrors
`core.deform.interpolate_keyframes` and `lbs.mjs` `interpolatePoses`; an Elixir
test (`framer/apps/framer_web/test/framer_web/rig_test.exs`) keeps it tied to
`lbs.mjs` so it cannot drift from the browser preview.

## Character and background layers

A still holds the character and the background in one picture, so a bone whose
influence reaches both deforms both. That is the documented behaviour of the
influence weighting, not a defect - a wide radius over a small character simply
reaches the background. The Layers panel adds the editing capability that
separates them: **Extract the character** splits the still into a character
layer and a background layer, and from then on the rig deforms the character
layer only. The background stays put while the character moves, in the preview
and in the final render alike.

The split is produced with the engine's existing background-removal
segmentation (the `remove-bg` operation's own colour key, run over the single
still); there is no second segmenter or model. Its alpha is the character mask,
which is recorded exactly - no feathering or cleanup by default - so the character layer
carries none of the background:

* **character layer** - the still's colour with the mask as its alpha, so the
  cut-out is exactly the pixels the background removal kept. It is written to
  `character.png` beside the still and is the only layer the rig resamples.
* **background layer** - an opaque *plate*: a full copy of the still whose
  character area is reconstructed from the surrounding background, so it covers
  every pixel. It is materialised once at split time, written to
  `background.png` beside the cut-out, and never resampled, so it is identical
  in every frame.

### Layers panel and per-layer actions

The Layers panel (`#layers-panel`) lists every layer belonging to the project:
1. **Source still** (`#layer-row-source`) - the original uploaded image. Can be replaced with **Change** to point the rig at an updated source.
2. **Character layer** (`#layer-row-character`) - the segmented character cut-out. Shows whether it is extracted, kept, or removed. Can be removed, restored with **Keep**, or replaced with **Change**.
3. **Background layer** (`#layer-row-background`) - the background plate. Can be removed, restored with **Keep**, or replaced with **Change**. On an unsplit rig, clicking **Remove** on the background layer extracts the character and drops the background in a single step.
4. **Patch layer** (`#layer-row-patch`) - the feathered reconstruction of the ground the character uncovers. It is materialised by the engine, and **Compute patch** asks for it. The row says whether it is ready, still to be computed, waiting for a skeleton, off, or stale - a patch that was built with another feather than the document records.

**The patch feather** (`#layer-fade-form`) is a 0-40 px slider, recorded in the document as `layers.fade`. It is the width of the feather at the region's edge, and it is saved with the project, so it travels with the rig. `0` is a valid width: the patch without a feather. A rig that records no fade at all has no patch layer and renders exactly as it did before the patch existed.

**When the patch applies**: the patch is built from the rig's motion, the feather and the layer files, so a change to any of them makes the materialised patch stale and the editor drops it - the row then says *not computed* and the preview stops compositing it. That happens when the slider moves, when the motion changes (a bone is moved, a keyframe is recorded) and when a layer is replaced or re-extracted. The feather and the motion apply when the patch is computed again: **Compute patch** is the trigger, and so is the next render or export (the engine rebuilds the patch when the rig no longer matches it). Dragging the slider never triggers an engine call of its own - the patch is a project-level artefact, so it is built once and reused.

**No-background outcome**: When the background layer is removed (`layers.background: false`), the deformed character layer renders alone against a transparent background. The viewport preview, frame render, and video export (WebM with alpha) all reflect this transparent outcome. The patch is a heal against the plate, so it is not used in that outcome either.

### The background patch

The plate reconstructs the character's *rest footprint* - the ground it stood on.
But a character also *travels*: the union of its warped footprints over the
timeline reaches past the rest footprint, and there the plate still shows the
untouched background. The character therefore slides from the plate's
reconstruction onto the original background - two different materials under one
moving character.

The **patch** is the third materialised layer that closes that gap. It is
computed from the skeleton with the engine's own LBS: the *region* is the
character's swept area (the union of its warped footprints over the timeline,
minus its rest footprint), the *reconstruction* fills that region from the
plate, and the *feather* is an alpha ramp over the region - fully opaque in
the middle, clear at the edge - so the patch merges into the untouched
background around it.

The stack is **character -> feathered patch -> opaque plate**, and the feather
is on the patch, never on the plate: a feathered plate would leave a
transparent ring in every frame, while the opaque plate underneath keeps every
frame fully opaque.

It is a *project-level* artefact: computed once from the skeleton, written
beside the still as `patch.png`, and reused by every frame, every preview and
every export. It needs a skeleton - the region the character can uncover is
only known once the bones and the timeline exist - so **Compute patch** is
disabled until the rig has one, and the engine rebuilds the patch when the rig
it came from changes. The patch is built from the character layer and the
background plate, so replacing either of them rebuilds it as well. The editor
drops the materialised patch as soon as one of its inputs changes, so the
preview never shows a patch the engine would rebuild.

**What it promises, honestly**: on a flat or gradient background the patch
reproduces the background almost exactly. On a textured background it is a
*plausible reconstruction* of the ground the character uncovers, not a recovery
of the original pixels - no inpainting method is the latter. The character
reads as the same character on top of a coherent material; the pixels
underneath it where it used to be are a reconstruction, as they already were
with the plate alone.

### Fill of a vacated region

When the background layer is kept, the two layers are recomposited with a plain source-over (the character over the
plate), so an opaque character pixel wins outright wherever it moves - including
over background it did not occupy at rest, where no blending happens. Where the
character moves away from, the plate shows through: the vacated region is never
transparent and never the character's original pixels, it is the reconstructed
background. Because the plate is opaque when kept, a split rig's frames are opaque too, so
an MP4 export encodes that region as the reconstructed background rather than
flattening a hole to black (when the background layer is removed, the frames carry
transparency and export to an alpha-capable format such as WebM).

### Limits of the split

* The key is colour-based. It separates whatever differs from the background
  colour, which is detected from the still's own border. A character that
  shares colours with the background, a background that is not close to a flat
  colour, or a background that touches the frame edges unevenly, produces a
  rougher cut-out; the **Background tolerance** slider (10-90) trades catching
  more of the background against biting into the character, and changing it
  re-extracts the cut-out.
* The plate is a reconstruction, not the original pixels: the character's own
  footprint is filled from the background around it, so a large or detailed
  character leaves a smoother approximation of what was behind it where it
  moves away.
* The split state is per rig document (`layers` in `framer.rig` v1), so a rig
  saved before this capability existed has no `layers` field and renders as
  one still exactly as before. Turning the split off drops the field again.

## Persistence

Filesystem-first, with Ecto/Postgres still disabled. `FramerWeb.RigStore` owns
one directory per project under the projects root (`:framer_web, :projects_dir`,
default `apps/framer_web/priv/projects`):

```
<root>/<rig-id>/
  source.png      # uploaded still (or source_replaced.<ext> when changed)
  character.png   # the materialised character layer, once split (or character_replaced.<ext>)
  background.png  # the materialised background plate, once split (or background_replaced.<ext>)
  patch.png       # the materialised background patch, once a rig records a fade
  patch.json      # what the patch was built from, so a changed rig rebuilds it
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
| `GET` | `/api/rigs/:id/character` | the materialised character layer of a split rig |
| `GET` | `/api/rigs/:id/background` | the materialised background plate of a split rig |
| `GET` | `/api/rigs/:id/patch` | the materialised background patch of a split rig |
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
the same shape as the engine's `port_integration_test.exs`. It also carries the
layer proofs end to end: a split rig's background pixels are byte-identical
between the rest frame and the posed frame, the character layer moves, and the
vacated region shows the reconstructed plate instead of the character's own
pixels. The engine-side proof lives in `tests/test_layered_deform.py` over the
same scene (`tests/layer_scene.py`), including a video export whose background
stays put while the unsplit export of the same scene drifts.

The browser proof suite (`browser_preview_test.exs`, tagged
`:requires_chromium`) drives the real Chromium through
`tests/browser/editor_runner.mjs` (playwright-core, no browser download) and
asserts preview pixels on saved `#viewport` screenshots - the browser-level
regressions for the slice-1 blank-preview defect and, since slice 4, for
viewport resize, WebGL context loss/recovery and fullscreen re-measure. It also
covers click precision (a bone landing where clicked at non-1 DPR, after a
resize, and on EXIF-rotated photographs whose displayed dimensions differ from
their stored pixels), overlay alignment (the drawn overlay sitting under the
pointer on a letterboxed portrait still, where the overlay once drew one
letterbox off, and on a still whose aspect matches the element), the
call-to-action handles (the move handle posing rather than mutating rest
geometry, the rotate handle dragging the tail without a start jump), and
viewport zoom (the `Ctrl`/`Cmd`+wheel shortcut and the in/out/fit controls
rescaling the still while a bone placed after a zoom still lands exactly under
the pointer). It also proves a drag renders live: pressing a placed bone's
joint or body and moving the pointer draws the joint under the pointer before
the release that commits it, and that pressing the drawn bone inside the
window that release holds (before the server's rig event lands) hits the drawn
bone rather than creating one and commits the next edit on top of that one. It
also proves that window outlives a burst of edits: every acknowledgement the
server pushes while two edits are in flight is recorded with the pose it drew,
so the bone can never be drawn back through a pose it had already passed. It
also drives the link handle end to end: dragging one bone's
link dot onto another sets the parent on the persisted rig and paints the
dotted parent link on the overlay canvas, a drag that would cycle the
hierarchy is refused with the same inline error the dropdown shows, and the
chain case proves the nearest-affordance rule - a grab on a dot drawn over
another bone's barrel moves or selects that bone instead of starting a link,
and a mis-grab released over a third bone leaves the persisted parent
unchanged. It excludes itself when
Chromium, Node or the built editor assets are missing, so to run it locally,
install the harness and build the assets first:

```bash
(cd tests/browser && npm ci)
(cd framer && MIX_ENV=dev mix assets.setup)
(cd framer && MIX_ENV=dev mix assets.build)
cd framer && mix test
```
