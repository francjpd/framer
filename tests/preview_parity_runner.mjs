// Node harness for the preview/final golden-parity test.
//
// Loads the editor's preview math (`lbs.mjs`), renders one frame from a raw
// RGBA source, and writes the raw RGBA result. `tests/test_preview_parity.py`
// builds the spec, runs this with Node, and compares the output against the
// authoritative Python `DeformRenderer`.
//
// Usage: node tests/preview_parity_runner.mjs spec.json

import fs from "node:fs";

import {
  computeDenseWeights,
  interpolatePoses,
  renderFrameRGBA,
} from "../framer/apps/framer_web/assets/js/lbs.mjs";

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

if (spec.source) {
  const source = new Uint8Array(fs.readFileSync(spec.source));

  const output = renderFrameRGBA(source, spec.width, spec.height, spec.rig, spec.frame, {
    iterations: spec.iterations,
  });

  fs.writeFileSync(spec.output, Buffer.from(output));
}

if (spec.weights_output) {
  const weights = computeDenseWeights(spec.rig, spec.width, spec.height);
  fs.writeFileSync(spec.weights_output, Buffer.from(weights.buffer));
}

if (spec.poses_output) {
  const frames = spec.poses_frames || [];
  const poses = {};
  for (const frame of frames) poses[String(frame)] = interpolatePoses(spec.rig, frame);
  fs.writeFileSync(spec.poses_output, JSON.stringify(poses));
}
