// Pure linear-blend-skinning math for the Framer editor preview.
//
// This module is deliberately DOM-free: the `LbsPreview` phx-hook (browser)
// and the Node golden-parity test both import it. It mirrors `core/deform.py`
// function for function - dense per-pixel weights, bone hierarchy evaluation,
// the fixed-point backward map and a bilinear remap - so the interactive
// preview and the server's final render agree by construction.
//
// The BEAM never sees any of this: it stays entirely on the client (or in the
// test process), and the engine is the authority for final output.

export const SCHEMA = "framer.rig";
export const VERSION = 1;
export const DEFAULT_RADIUS = 10.0;
export const DEFAULT_POWER = 2.0;

// ---------------------------------------------------------------------------
// numeric helpers
// ---------------------------------------------------------------------------

// Round half to even, matching numpy.rint.
export function rint(value) {
  const floor = Math.floor(value);
  const diff = value - floor;
  if (diff > 0.5) return floor + 1;
  if (diff < 0.5) return floor;
  return floor % 2 === 0 ? floor : floor + 1;
}

function clamp(value, low, high) {
  return value < low ? low : value > high ? high : value;
}

export function falloffPower(falloff, defaultPower) {
  if (falloff === "linear") return 1.0;
  if (falloff === "hard") return 0.0;
  return defaultPower;
}

export function rigWidth(rig) {
  return rig.canvas.width;
}

export function rigHeight(rig) {
  return rig.canvas.height;
}

// ---------------------------------------------------------------------------
// dense weights (mirrors computeDenseWeights / compute_dense_weights)
// ---------------------------------------------------------------------------

/**
 * Compute the dense per-pixel bone weights, `(numBones * height * width)` in
 * bone-major order, normalised along the bone axis with a nearest-bone
 * fallback. Identical to the engine's bind-time weights.
 */
export function computeDenseWeights(rig, width, height) {
  const w = width ?? rig.canvas.width;
  const h = height ?? rig.canvas.height;
  const bones = rig.bones;
  const count = bones.length;
  const bind = rig.bind || {};
  const power = bind.power ?? DEFAULT_POWER;
  const radiusScale = bind.radius_scale ?? 1.0;
  const plane = w * h;

  const weights = new Float32Array(count * plane);
  const distances = new Float32Array(count * plane);

  for (let b = 0; b < count; b++) {
    const bone = bones[b];
    const [ax, ay] = bone.rest.head;
    const [bx, by] = bone.rest.tail;
    const radius = (bone.radius ?? DEFAULT_RADIUS) * radiusScale;
    const exponent = falloffPower(bone.falloff || "smooth", power);
    const vx = bx - ax;
    const vy = by - ay;
    const segLen2 = vx * vx + vy * vy;
    const base = b * plane;

    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let distance;
        if (segLen2 <= 1e-12) {
          const dx = x - ax;
          const dy = y - ay;
          distance = Math.sqrt(dx * dx + dy * dy);
        } else {
          const wx = x - ax;
          const wy = y - ay;
          const t = clamp((wx * vx + wy * vy) / segLen2, 0, 1);
          const dx = wx - t * vx;
          const dy = wy - t * vy;
          distance = Math.sqrt(dx * dx + dy * dy);
        }

        const index = base + y * w + x;
        distances[index] = distance;

        let influence = clamp(1 - distance / Math.max(radius, 1e-6), 0, 1);
        influence = exponent === 0 ? (influence > 0 ? 1 : 0) : Math.pow(influence, exponent);
        weights[index] = influence;
      }
    }
  }

  const normalised = new Float32Array(count * plane);
  for (let i = 0; i < plane; i++) {
    let total = 0;
    for (let b = 0; b < count; b++) total += weights[b * plane + i];

    if (total > 0) {
      for (let b = 0; b < count; b++) {
        normalised[b * plane + i] = weights[b * plane + i] / Math.max(total, 1e-8);
      }
    } else {
      let nearest = 0;
      let best = Infinity;
      for (let b = 0; b < count; b++) {
        const d = distances[b * plane + i];
        if (d < best) {
          best = d;
          nearest = b;
        }
      }
      normalised[nearest * plane + i] = 1;
    }
  }

  return normalised;
}

/** Apply a row-major 3x3 matrix to a point `[x, y]`. */
export function applyMatrix(m, point) {
  const [x, y] = point;
  return [m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5]];
}

// ---------------------------------------------------------------------------
// control mesh (mirrors compute_vertex_weights)
// ---------------------------------------------------------------------------

/**
 * Weight mesh vertices with the same distance/radius/falloff rule as pixels.
 * Returns an array of per-bone weight arrays (row sums to 1).
 */
export function computeVertexWeights(rig, vertices) {
  const bones = rig.bones;
  const bind = rig.bind || {};
  const power = bind.power ?? DEFAULT_POWER;
  const radiusScale = bind.radius_scale ?? 1.0;

  const segments = bones.map((bone) => [
    bone.rest.head[0],
    bone.rest.head[1],
    bone.rest.tail[0],
    bone.rest.tail[1],
  ]);

  const distances = vertices.map(([px, py]) =>
    segments.map(([ax, ay, bx, by]) => {
      const vx = bx - ax;
      const vy = by - ay;
      const wx = px - ax;
      const wy = py - ay;
      const segLen2 = vx * vx + vy * vy;
      if (segLen2 <= 1e-12) return Math.hypot(wx, wy);
      const t = clamp((wx * vx + wy * vy) / segLen2, 0, 1);
      return Math.hypot(wx - t * vx, wy - t * vy);
    })
  );

  return distances.map((row) => {
    const raw = row.map((distance, b) => {
      const bone = bones[b];
      const radius = (bone.radius ?? DEFAULT_RADIUS) * radiusScale;
      const exponent = falloffPower(bone.falloff || "smooth", power);
      const base = clamp(1 - distance / Math.max(radius, 1e-6), 0, 1);
      return exponent === 0 ? (base > 0 ? 1 : 0) : Math.pow(base, exponent);
    });

    const total = raw.reduce((sum, value) => sum + value, 0);
    if (total > 0) return raw.map((value) => value / Math.max(total, 1e-8));

    let nearest = 0;
    let best = Infinity;
    row.forEach((distance, b) => {
      if (distance < best) {
        best = distance;
        nearest = b;
      }
    });
    return raw.map((_value, b) => (b === nearest ? 1 : 0));
  });
}

/** Deform a single point with its per-bone weights and the bone world matrices. */
export function skinPoint(point, weights, world) {
  let x = 0;
  let y = 0;
  for (let b = 0; b < weights.length; b++) {
    const w = weights[b];
    if (w === 0) continue;
    const m = world[b];
    x += w * (m[0] * point[0] + m[1] * point[1] + m[2]);
    y += w * (m[3] * point[0] + m[4] * point[1] + m[5]);
  }
  return [x, y];
}

/**
 * Pack up to four bone weights into an RGBA8 texture for the WebGL2 path.
 * `mesh` is the dense weight field; bones beyond the fourth are dropped (the
 * hook falls back to the CPU renderer in that case).
 */
export function buildWeightTexture(weights, count, w, h) {
  const plane = w * h;
  const used = Math.min(count, 4);
  const texture = new Uint8Array(plane * 4);

  for (let i = 0; i < plane; i++) {
    for (let b = 0; b < used; b++) {
      texture[i * 4 + b] = Math.round(clamp(weights[b * plane + i], 0, 1) * 255);
    }
  }

  return texture;
}

// ---------------------------------------------------------------------------
// bone evaluation / keyframes (mirrors evaluate_bones / interpolate_keyframes)
// ---------------------------------------------------------------------------

// Row-major 3x3 local matrix: rotation about the rest head plus translation.
export function boneLocalMatrix(head, pose) {
  const rot = pose.rot || 0;
  const tx = pose.tx || 0;
  const ty = pose.ty || 0;
  const c = Math.cos(rot);
  const s = Math.sin(rot);
  const [hx, hy] = head;

  return [c, -s, hx - c * hx + s * hy + tx, s, c, hy - s * hx - c * hy + ty, 0, 0, 1];
}

export function multiply(a, b) {
  return [
    a[0] * b[0] + a[1] * b[3] + a[2] * b[6],
    a[0] * b[1] + a[1] * b[4] + a[2] * b[7],
    a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
    a[3] * b[0] + a[4] * b[3] + a[5] * b[6],
    a[3] * b[1] + a[4] * b[4] + a[5] * b[7],
    a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
    a[6] * b[0] + a[7] * b[3] + a[8] * b[6],
    a[6] * b[1] + a[7] * b[4] + a[8] * b[7],
    a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
  ];
}

const ZERO_POSE = { rot: 0, tx: 0, ty: 0 };

function poseFor(poseMap, id) {
  const pose = (poseMap && poseMap[id]) || {};
  return { rot: pose.rot || 0, tx: pose.tx || 0, ty: pose.ty || 0 };
}

export function interpolatePoses(rig, frame) {
  const keyframes = (rig.keyframes || []).slice().sort((a, b) => a.frame - b.frame);
  const bones = rig.bones;
  const result = {};

  if (keyframes.length === 0) {
    for (const bone of bones) result[bone.id] = { ...ZERO_POSE };
    return result;
  }

  const first = keyframes[0];
  const last = keyframes[keyframes.length - 1];

  if (frame <= first.frame) {
    for (const bone of bones) result[bone.id] = poseFor(first.pose, bone.id);
    return result;
  }

  if (frame >= last.frame) {
    for (const bone of bones) result[bone.id] = poseFor(last.pose, bone.id);
    return result;
  }

  let left = first;
  let right = last;
  for (let i = 0; i < keyframes.length - 1; i++) {
    if (keyframes[i].frame <= frame && frame <= keyframes[i + 1].frame) {
      left = keyframes[i];
      right = keyframes[i + 1];
      break;
    }
  }

  const span = right.frame - left.frame;
  const t = span <= 0 ? 0 : (frame - left.frame) / span;

  for (const bone of bones) {
    const lp = poseFor(left.pose, bone.id);
    const rp = poseFor(right.pose, bone.id);
    result[bone.id] = {
      rot: lp.rot + (rp.rot - lp.rot) * t,
      tx: lp.tx + (rp.tx - lp.tx) * t,
      ty: lp.ty + (rp.ty - lp.ty) * t,
    };
  }

  return result;
}

/**
 * World transform (row-major 3x3) for every bone at `frame`, in rig order.
 */
export function evaluateBones(rig, frame, poses) {
  const resolved = poses || interpolatePoses(rig, frame);
  const byId = new Map(rig.bones.map((bone) => [bone.id, bone]));
  const world = new Map();

  function resolve(bone, stack) {
    if (world.has(bone.id)) return world.get(bone.id);
    if (stack.includes(bone.id)) throw new Error(`cycle detected at bone ${bone.id}`);

    const local = boneLocalMatrix(bone.rest.head, resolved[bone.id] || ZERO_POSE);
    const parent = bone.parent ? byId.get(bone.parent) : null;
    const matrix = parent ? multiply(resolve(parent, [...stack, bone.id]), local) : local;
    world.set(bone.id, matrix);
    return matrix;
  }

  return rig.bones.map((bone) => resolve(bone, []));
}

// ---------------------------------------------------------------------------
// skinning / backward map / remap (mirrors skinning_fields + compute_backward_map)
// ---------------------------------------------------------------------------

/**
 * Per-pixel skinning matrix field `A` (4 floats: a00,a01,a10,a11) and
 * translation field `T` (2 floats), flattened row-major over the canvas.
 */
export function skinningFields(weights, world, count, w, h) {
  const plane = w * h;
  const A = new Float32Array(plane * 4);
  const T = new Float32Array(plane * 2);

  // The bind pose is the identity (the engine evaluates bind with identity
  // local poses), so the skinning matrix is the world matrix.
  const matrices = world.map((m) => [m[0], m[1], m[3], m[4]]);
  const translations = world.map((m) => [m[2], m[5]]);

  for (let i = 0; i < plane; i++) {
    let a00 = 0;
    let a01 = 0;
    let a10 = 0;
    let a11 = 0;
    let tx = 0;
    let ty = 0;

    for (let b = 0; b < count; b++) {
      const weight = weights[b * plane + i];
      const m = matrices[b];
      const t = translations[b];
      a00 += weight * m[0];
      a01 += weight * m[1];
      a10 += weight * m[2];
      a11 += weight * m[3];
      tx += weight * t[0];
      ty += weight * t[1];
    }

    A[i * 4] = a00;
    A[i * 4 + 1] = a01;
    A[i * 4 + 2] = a10;
    A[i * 4 + 3] = a11;
    T[i * 2] = tx;
    T[i * 2 + 1] = ty;
  }

  return { A, T };
}

/**
 * Solve `F(p) = q` for every output pixel with the engine's fixed-point
 * iteration; returns `{mapX, mapY}` for the remap.
 */
export function computeBackwardMap(A, T, w, h, iterations) {
  const plane = w * h;
  const mapX = new Float32Array(plane);
  const mapY = new Float32Array(plane);
  let estimateX = new Float32Array(plane);
  let estimateY = new Float32Array(plane);

  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      estimateX[i] = x;
      estimateY[i] = y;
    }
  }

  const steps = Math.max(1, iterations | 0);
  const nextX = new Float32Array(plane);
  const nextY = new Float32Array(plane);

  for (let step = 0; step < steps; step++) {
    for (let i = 0; i < plane; i++) {
      const queryX = i % w;
      const queryY = (i - queryX) / w;
      const sampleX = clamp(rint(estimateX[i]), 0, w - 1);
      const sampleY = clamp(rint(estimateY[i]), 0, h - 1);
      const j = sampleY * w + sampleX;

      const a = A[j * 4];
      const b = A[j * 4 + 1];
      const c = A[j * 4 + 2];
      const d = A[j * 4 + 3];
      const det = a * d - b * c;
      const safe = Math.abs(det) < 1e-8 ? 1e-8 : det;

      const rhsX = queryX - T[j * 2];
      const rhsY = queryY - T[j * 2 + 1];

      nextX[i] = (d * rhsX - b * rhsY) / safe;
      nextY[i] = (-c * rhsX + a * rhsY) / safe;
    }

    estimateX = nextX.slice();
    estimateY = nextY.slice();
  }

  mapX.set(estimateX);
  mapY.set(estimateY);
  return { mapX, mapY };
}

/**
 * Bilinear remap of an RGBA buffer, matching cv2.remap(INTER_LINEAR,
 * BORDER_CONSTANT, 0).
 */
export function remapBilinear(source, w, h, mapX, mapY) {
  const out = new Uint8ClampedArray(w * h * 4);

  function sample(index, channel) {
    if (index < 0 || index >= w * h) return 0;
    return source[index * 4 + channel];
  }

  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      const fx = mapX[i];
      const fy = mapY[i];
      const x0 = Math.floor(fx);
      const y0 = Math.floor(fy);
      const ax = fx - x0;
      const ay = fy - y0;

      const topLeft = y0 * w + x0;
      const topRight = y0 * w + (x0 + 1);
      const bottomLeft = (y0 + 1) * w + x0;
      const bottomRight = (y0 + 1) * w + (x0 + 1);

      for (let c = 0; c < 4; c++) {
        const value =
          sample(topLeft, c) * (1 - ax) * (1 - ay) +
          sample(topRight, c) * ax * (1 - ay) +
          sample(bottomLeft, c) * (1 - ax) * ay +
          sample(bottomRight, c) * ax * ay;

        out[i * 4 + c] = value;
      }
    }
  }

  return out;
}

/** Convenience: render one frame to an RGBA buffer (the 2D-canvas fallback). */
export function renderFrameRGBA(source, w, h, rig, frame, options = {}) {
  const iterations = options.iterations ?? 5;
  const count = rig.bones.length;
  const weights = options.weights || computeDenseWeights(rig, w, h);
  const world = evaluateBones(rig, frame);
  const { A, T } = skinningFields(weights, world, count, w, h);
  const { mapX, mapY } = computeBackwardMap(A, T, w, h, iterations);
  return remapBilinear(source, w, h, mapX, mapY);
}
