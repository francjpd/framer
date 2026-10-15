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
    "color": null,
    "tolerance": 40,
    "auto_ranges": true,
    "num_ranges": 5,
    "adaptive_bg": false,
    "edge_cleanup": 3,
    "soft_edges": 5
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
| `layers` | no | the optional character/background split; absent means the legacy single-picture render, which is how a rig saved before the split existed keeps loading and rendering unchanged. `layers.split` (boolean) turns it on; `layers.character` names the materialised character-layer file (resolved against the still's directory, default `character.png`, or `false` if removed); `layers.background` names the background plate file (default `background.png`, or `false` to remove the background entirely for a character-only transparent render/export); the remaining keys record the background-removal settings the mask was built with (`color`, `tolerance`, `auto_ranges`, `num_ranges`, `adaptive_bg`, `edge_cleanup`, `soft_edges`). See [Layered deformation](#layered-deformation) |

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
`character.png` beside the still, and `background.png`) are materialised once
with the engine's existing background-removal segmentation and reused by later
renders, exports and the editor's preview.

Each layer can be independently kept, removed, or changed. In particular, when the background layer is removed (`layers.background: false`), the engine skips compositing over the plate and renders only the deformed character layer with its transparent alpha channel intact (the no-background outcome), which carries through to preview, frame render, and video export (e.g. WebM with alpha).

When the background plate is present, the composite is a plain source-over, so an opaque character pixel wins
outright wherever it moves - including over background it did not occupy at
rest. Where the character moves away from, the plate shows through: the
vacated region carries the reconstructed background, never the character's
original pixels, and because the plate is opaque the composited frame is opaque
too. The preview (`assets/js/lbs.mjs`) mirrors the split, layer visibility, and composite
exactly, and `tests/test_preview_parity.py` keeps the two in agreement.

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
    "still": true
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
* The response reports the materialised character-layer path when the engine
  wrote it (the plate is written beside it under its own fixed name).
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
