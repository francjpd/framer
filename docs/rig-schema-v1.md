# Framer rig schema v1 (`framer.rig`)

The `deform` engine operation is a 2D rig/bones puppet warp: a still image is
bound to a small skeleton and deformed frame by frame over a timeline.  The rig
is a versioned JSON document, `framer.rig` version `1`, stored on disk and
referenced by **path** in the Port request.  The BEAM never receives the rig's
weights or any pixel data - only the path, the frame range and JSON options.

The authoritative loader/validator is `core/deform.py:load_rig` /
`validate_rig`.  An unknown `schema` or `version` fails loudly and surfaces as a
normal Port error; a document that does not validate never renders.

## Document

```jsonc
{
  "schema": "framer.rig",
  "version": 1,
  "id": "b1c2...",
  "canvas": { "width": 640, "height": 480 },
  "source": { "kind": "image", "path": "assets/character.png", "frame": 0 },
  "duration": { "fps": 24, "frames": 120 },

  "mesh": {
    "mode": "grid",
    "vertices": [[x, y], ...],
    "triangles": [[i, j, k], ...],
    "weights": [[b0, b1, ...], ...]
  },

  "bones": [
    {
      "id": "b0",
      "name": "root",
      "parent": null,
      "rest": { "head": [320, 400], "tail": [320, 240] },
      "radius": 128,
      "falloff": "smooth"
    }
  ],

  "bind": { "mode": "auto", "power": 2.0, "radius_scale": 1.0 },

  "keyframes": [
    { "frame": 0,  "pose": { "b0": { "rot": 0.0, "tx": 0, "ty": 0 } } },
    { "frame": 30, "pose": { "b0": { "rot": 0.4, "tx": 0, "ty": 0 } } }
  ],

  "playback": { "loop": true },

  "layers": {
    "split": true,
    "character": "character.png",
    "background": "background.png",
    "color": null,
    "tolerance": 40,
    "auto_ranges": true,
    "num_ranges": 5,
    "adaptive_bg": false,
    "edge_cleanup": 3,
    "soft_edges": 5,
    "fade": 12
  }
}
```

### Fields

| Field | Required | Notes |
| --- | --- | --- |
| `schema` | yes | must be `"framer.rig"` |
| `version` | yes | must be `1`; other versions are rejected |
| `canvas.width` / `canvas.height` | yes | positive integers; the render output size |
| `bones[]` | yes | non-empty; each bone needs a unique `id` and a `rest.head`/`rest.tail` |
| `bones[].name` | no | the readable handle for a person or an agent (`FramerWeb.Rig` defaults a fresh bone to `"bone N"`); `bones[].id` remains the key the keyframe map uses |
| `bones[].parent` | no | `null` or another bone `id`; the hierarchy must be acyclic |
| `bones[].radius` | no | influence radius in pixels. The engine default is `10` (`core/deform.py` `DEFAULT_RADIUS`); the editor instead auto-assigns `max(canvas.width, canvas.height) / 5`, floored at 16 px, when a bone is created (`FramerWeb.Rig.auto_radius`) |
| `bones[].falloff` | no | `smooth` (default), `linear`, or `hard` |
| `bind.power` | no | falloff exponent for `smooth`, default `2.0` |
| `bind.radius_scale` | no | multiplies every bone radius, default `1.0` |
| `keyframes[]` | no | each `{frame, pose}` with a per-bone `{rot, tx, ty}` local pose |
| `duration.frames` / `duration.fps` | no | used to loop a still when the request omits a range |
| `mesh`, `source`, `playback`, `id` | no | written by the editor (`FramerWeb.Rig.new`, `FramerWeb.Rig.auto_bind`); the engine ignores them |
| `layers` | no | the optional character/background split; absent means the legacy single-picture render, which is how a rig saved before the split existed keeps loading and rendering unchanged. `layers.split` (boolean) turns it on; `layers.character` names the materialised character-layer file (resolved against the still's directory, default `character.png`, or `false` if removed); `layers.background` names the background plate file (default `background.png`, or `false` to remove the background entirely for a character-only transparent render/export); `layers.fade` is the width in pixels of the background patch's feather (default `12`, `0` = no feather) and is what enables the patch layer at all - a document that records no `fade` has no patch and renders exactly as it did before the patch existed; the remaining keys record the background-removal settings the mask was built with (`color`, `tolerance`, `auto_ranges`, `num_ranges`, `adaptive_bg`, `edge_cleanup`, `soft_edges`). See [Layered deformation](#layered-deformation) |

The editor's auto-radius is deliberate, not a divergence to align away: at the
engine default of 10 px a fresh bone's influence is tiny, so the nearest-bone
fallback would bind every pixel rigidly and the editor would read as "bones do
nothing". Aligning the editor to 10 px was deliberately not chosen; the
auto-scale is the intended editor behaviour, and the Properties slider adjusts
the radius from there.

Coordinates are image space: `x` right, `y` down, origin top-left.  `rot` is
radians.  Weights are **derived** from bones, never read from `mesh.weights` by
the engine.

## Deformation model

* **Bone transform.** A bone's local pose is a rotation about its rest `head`
  followed by a translation: `L = T(head) R(rot) T(-head) + (tx, ty)`.  World
  transforms compose down the parent chain, `W_b = W_parent · L_b`.
* **Weights.** Every pixel gets a dense weight per bone,
  `w_b(p) = clamp(1 - d_b(p) / radius_b, 0, 1) ** power`, where `d_b` is the
  distance to the bone segment.  Weights are normalised across bones; pixels
  outside every radius fall back to their nearest bone.  Weights depend only on
  the bind pose and are cached in-process (and optionally in an `.npz` file via
  `options.weights`).
* **Rendering.** Linear blend skinning gives `M(p) = Σ w_b(p) A_b` and
  `t(p) = Σ w_b(p) t_b`.  The backward map has no closed form, so it is solved
  with a fixed-point iteration (`iterations`, default `5`) and sampled with
  `cv2.remap`, preserving alpha.

## Layered deformation

A document with `layers.split` true is rendered split: the still is separated
into a **character layer** (the still's colour with the background-removal
mask as its alpha) and an optional **background layer** - an opaque *plate*, a full copy
of the still whose character area is reconstructed from the surrounding
background, so no pixel is left uncovered. When both layers are present, only the character layer is
resampled; the plate is composited underneath it untouched, so the background is
identical in every frame. The two files (`layers.character`, default
`character.png` beside the still, and `layers.background`, default `background.png`) are materialised once
with the engine's existing background-removal segmentation and reused by later
renders, exports and the editor's preview. A document that records a feather
adds a third layer between the two - the background patch, described in
[The background patch](#the-background-patch).

Each layer can be independently kept, removed, or changed. In particular, when the background layer is removed (`layers.background: false`), the engine skips compositing over the plate and renders only the deformed character layer with its transparent alpha channel intact (the no-background outcome), which carries through to preview, frame render, and video export (e.g. WebM with alpha).

When the background plate is present, the composite is a plain source-over, so an opaque character pixel wins
outright wherever it moves - including over background it did not occupy at
rest. Where the character moves away from, the plate shows through: the
vacated region carries the reconstructed background, never the character's
original pixels, and because the plate is opaque the composited frame is opaque
too. The preview (`assets/js/lbs.mjs`) mirrors the split, the layer visibility,
the patch layer and the composite exactly, and `tests/test_preview_parity.py`
keeps the two in agreement.

## The background patch

A document that records `layers.fade` is rendered with a **third** materialised
layer between the character and the plate: the **patch** (`patch.png` beside
the still). The stack is *character -> feathered patch -> opaque plate*.

* **The region** is the character's *swept area*: the union of its warped
  footprints over the whole timeline, minus its own rest footprint. It is
  computed from the skeleton with the engine's own LBS (`compute_dense_weights`
  -> `evaluate_bones` -> `apply_lbs` over the character mask), so it is exactly
  the ground the character can uncover. Every frame of the timeline is
  sampled, so the union has no hole where the character travels.
* **The reconstruction** fills that region from the *plate*, never from the
  still: inpainting from the still leaks the character's own pixels into the
  result. The ordering is the measured one - the rest footprint is reconstructed
  first (that is the plate) and the swept-only part is inpainted from that
  plate, so the original background is preserved wherever the sweep merely
  passed over it, and the rest footprint keeps the plate's own reconstruction
  of it.
* **The feather** is an alpha ramp over the region (`cv2.distanceTransform`),
  fully opaque in the middle of the region and 0 at its edge, so the patch
  merges into the untouched background around it. `layers.fade` is its width in
  pixels.

The feather lives on the patch and never on the plate. A feathered *plate*
would leave a transparent ring in every frame; the opaque plate underneath an
opaque patch keeps the frame fully opaque (measured: 0 transparent pixels).

The patch is a **project-level artefact**: it is computed once from the
skeleton, written beside the still and reused by every frame, every preview and
every export. It is only computed for a rig that records a fade, has a
skeleton - the region is only known once the bones and the timeline exist - and
has the background plate to heal against. The engine records what the patch
was built from in `patch.json` beside it: a fingerprint of the rig's skeleton
and motion, of the feather, and of the *content* of the character layer and the
background plate it was built from - so a rig that changed, or a layer whose
bytes changed, rebuilds the patch instead of reusing a stale file.

**What it promises, honestly**: on a flat or gradient background the patch
reproduces the background almost exactly. On a textured background it is a
*plausible reconstruction* of the ground the character uncovers, not a recovery
of the original pixels - no inpainting method is the latter. The character
still reads as the same character on top of a coherent material; the pixels
underneath it where it used to be are a reconstruction, as they already were
with the plate alone.

## Request options

The operation travels through the normal Port contract
(`framer_worker.op_deform` / `ops.deform.deform_video`):

```jsonc
{
  "op": "deform",
  "input": "/abs/project/source.png",
  "output": "/abs/tmp/chunk_3.webm",
  "start_frame": 72, "end_frame": 95, "fps": 24.0,
  "options": {
    "rig": "/abs/project/rig.json",
    "weights": null,
    "iterations": 5,
    "radius_scale": 1.0,
    "still": true,
    "patch": "auto"
  }
}
```

* `input` is the still image.  It is read once and **looped** over
  `[start_frame, end_frame]`; the caller supplies `total_frames`/`fps` from
  `duration` (`submit_job` only requires `total_frames > 0`).  A video `input`
  uses its first frame as the source.
* `output` keeps the chunk extension.  An image extension (`.png`, `.jpg`, ...)
  renders a single frame instead of a video.
* `options.weights` is an optional dense-weight `.npz` cache path.
* `options.patch` decides what happens with the patch layer: `auto` (the
  default) materialises it when it is missing or stale, `reuse` uses the
  materialised patch and never builds one.  The editor's extraction and its
  single-frame render pass `reuse`, and so do the chunks of an export, so none
  of them pays for the whole-timeline region sweep.  The patch is materialised
  by the compute action, for the project, and by an export's job, for the
  export: it builds one in the export directory before it dispatches the
  chunks, so every chunk of that job composites the same file.
* The response reports the materialised character-layer path when the engine
  wrote it (the plate is written beside it under its own fixed name), and the
  patch layer in effect - the file the engine built or the one it reused.
* The renderer is stateless per chunk: it reloads the rig/weights from disk, so
  a failed chunk can be retried on any worker.

## Rendering / exporting

```bash
# One frame to PNG
.venv/bin/python cli.py deform still.png frame.png --rig rig.json --start-frame 12 --end-frame 12

# Full animation to an alpha-capable video
.venv/bin/python cli.py deform still.png out.webm --rig rig.json

# Through the Elixir orchestrator (chunked, then merged)
framer deform still.png out.webm --rig rig.json
```

## Editing a rig

The versioned document is also the editor's working format: the LiveView
rig/bones editor at `/editor` writes `framer.rig` v1 directly and drives the
same `deform` operation. It adds the optional `source`, `mesh` and `playback`
fields (the engine ignores them) so the viewport can reload and preview the
rig. See [`docs/rig-editor.md`](rig-editor.md).
