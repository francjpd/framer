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
      "radius": 140,
      "falloff": "smooth"
    }
  ],

  "bind": { "mode": "auto", "power": 2.0, "radius_scale": 1.0 },

  "keyframes": [
    { "frame": 0,  "pose": { "b0": { "rot": 0.0, "tx": 0, "ty": 0 } } },
    { "frame": 30, "pose": { "b0": { "rot": 0.4, "tx": 0, "ty": 0 } } }
  ],

  "playback": { "loop": true }
}
```

### Fields

| Field | Required | Notes |
| --- | --- | --- |
| `schema` | yes | must be `"framer.rig"` |
| `version` | yes | must be `1`; other versions are rejected |
| `canvas.width` / `canvas.height` | yes | positive integers; the render output size |
| `bones[]` | yes | non-empty; each bone needs a unique `id` and a `rest.head`/`rest.tail` |
| `bones[].parent` | no | `null` or another bone `id`; the hierarchy must be acyclic |
| `bones[].radius` | no | influence radius in pixels, default `10` |
| `bones[].falloff` | no | `smooth` (default), `linear`, or `hard` |
| `bind.power` | no | falloff exponent for `smooth`, default `2.0` |
| `bind.radius_scale` | no | multiplies every bone radius, default `1.0` |
| `keyframes[]` | no | each `{frame, pose}` with a per-bone `{rot, tx, ty}` local pose |
| `duration.frames` / `duration.fps` | no | used to loop a still when the request omits a range |
| `mesh`, `source`, `playback`, `id` | no | reserved for the editor (M3-M5) |

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

## Request options

The operation travels through the normal Port contract
(`framer_worker.op_deform` / `ops.deform.deform_video`):

```jsonc
{
  "op": "deform",
  "input": "/abs/project/character.png",
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
* The renderer is stateless per chunk: it reloads the rig/weights from disk, so
  a failed chunk can be retried on any worker.

## Rendering / exporting

```bash
# One frame to PNG
.venv/bin/python cli.py deform still.png frame.png --rig rig.json --start-frame 12 --end-frame 12

# Full animation to an alpha-capable video
.venv/bin/python cli.py deform still.png out.webm --rig rig.json

# Through the Elixir orchestrator (chunked, then merged)
mix run -e 'FramerCore.CLI.main(["deform", "still.png", "out.webm", "--rig", "rig.json"])'
```

## Editing a rig

The versioned document is also the editor's working format: the LiveView
rig/bones editor at `/editor` writes `framer.rig` v1 directly and drives the
same `deform` operation. It adds the optional `source`, `mesh` and `playback`
fields (the engine ignores them) so the viewport can reload and preview the
rig. See [`docs/rig-editor.md`](rig-editor.md).
