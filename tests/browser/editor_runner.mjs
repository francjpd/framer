#!/usr/bin/env node
// editor_runner.mjs — plain Node scenario runner for the Framer editor's
// browser proof harness.
//
// Usage: node editor_runner.mjs <scenario.json>
//
// The runner launches the *system* Chromium (never downloads a browser):
//   executablePath = process.env.FRAMER_CHROMIUM || "/usr/bin/chromium"
//   args            = --headless=new --use-gl=swiftshader --enable-webgl --no-sandbox
// (the exact launch recipe the framer audit used; swiftshader supplies the
// GL context the WebGL2 preview needs in headless mode).
//
// It walks the scenario steps, saves PNG screenshots of the #viewport region
// to the paths named in the spec, prints the step it failed on and exits
// non-zero on any failure. Pixel assertions are deliberately NOT done here:
// the Elixir suite decodes the PNGs and counts pixels (see
// browser_preview_test.exs), so no PNG library lives in this package.
//
// Scenario JSON shape:
//
// {
//   "baseUrl": "http://127.0.0.1:4002",
//   "viewport": {"width": 1280, "height": 900},     // optional browser window
//   "deviceScaleFactor": 1,                          // optional DPR (HiDPI)
//   "stepTimeoutMs": 30000,                          // optional per-wait timeout
//   "failureScreenshot": "/abs/path.png",            // optional, on failure
//   "steps": [
//     {"name": "human label", "open": "/editor"},                   // goto
//     {"name": "...", "waitForSelector": "#editor-shell"},          // wait visible
//     {"name": "...", "waitForSelector": {"selector": "css", "state": "attached"}},
//     {"name": "...", "waitForFunction": "() => <bool expr>"},      // poll until true
//     {"name": "...", "sleep": 1500},                               // settle (ms)
//     {"name": "...", "evaluate": "() => <expr>", "expect": {"eq": 0}},
//     {"name": "...", "fetch": {                                   // in-page fetch
//        "url": "/api/rigs", "method": "POST",
//        "headers": {"content-type": "application/json"},
//        "body": {"name": "..."}},
//      "saveAs": "create"},                       // JSON response -> templates
//     {"name": "...", "open": "/editor?rig={{create.rig.id}}"},     // {{path}}
//     {"name": "...", "click": {"selector": "#tool-bones"}},
//     {"name": "...", "drag": {                                    // mouse drag
//        "selector": "#viewport",
//        "from": {"fx": 0.5, "fy": 0.35},          // fraction of the box, or
//        "to":   {"x": 640, "y": 500},             // absolute page coords
//        "steps": 8, "settleMs": 300}},
//     {"name": "...", "dragImage": {                               // image coords
//        "from": [100, 50], "to": [140, 70],          // [ix, iy] in the image
//        "imgW": 200, "imgH": 100,                     // image dimensions
//        "steps": 8, "settleMs": 300}},
//     {"name": "...", "resize": {"width": 1600, "height": 1000}},
//     {"name": "...", "screenshot": {"path": "/abs/out.png", "selector": "#viewport"}}
//   ]
// }
//
// "expect" supports: eq, neq, gt, gte, lt, lte, truthy, falsy. Any string
// value in a step may contain {{path.to.value}} templates resolved from the
// JSON saved by "fetch" steps.

import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright-core";

const specPath = process.argv[2];
if (!specPath) {
  console.error("usage: node editor_runner.mjs <scenario.json>");
  process.exit(2);
}

let spec;
try {
  spec = JSON.parse(fs.readFileSync(specPath, "utf8"));
} catch (error) {
  console.error(`could not read scenario spec ${specPath}: ${error.message}`);
  process.exit(2);
}

function findExecutable(name) {
  const dirs = (process.env.PATH || "").split(path.delimiter);
  for (const dir of dirs) {
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // keep searching the next PATH entry
    }
  }
  return null;
}

const executablePath =
  process.env.FRAMER_CHROMIUM || findExecutable("chromium") || "/usr/bin/chromium";
if (!fs.existsSync(executablePath)) {
  console.error(
    `chromium not found at ${executablePath} — install Chromium or set FRAMER_CHROMIUM to its path`
  );
  process.exit(2);
}

const browser = await chromium
  .launch({
    executablePath,
    // Headless is requested through the launch args themselves (the audit's
    // recipe), so Playwright's own headless flag stays off.
    headless: false,
    args: ["--headless=new", "--use-gl=swiftshader", "--enable-webgl", "--no-sandbox"],
  })
  .catch((error) => {
    console.error(`could not launch ${executablePath}: ${error.message}`);
    process.exit(2);
  });

const context = await browser.newContext({
  viewport: spec.viewport || { width: 1280, height: 900 },
  deviceScaleFactor: spec.deviceScaleFactor || 1,
});

// Record page-side errors (exceptions, unhandled rejections, console.error
// calls) so a scenario can assert "zero page errors". Network-level console
// noise is deliberately not counted.
await context.addInitScript(() => {
  window.__framerErrors = [];
  window.addEventListener("error", (event) => {
    window.__framerErrors.push(`error: ${event.message}`);
  });
  window.addEventListener("unhandledrejection", (event) => {
    window.__framerErrors.push(`unhandledrejection: ${String(event.reason)}`);
  });
  const originalError = console.error.bind(console);
  console.error = (...args) => {
    window.__framerErrors.push(`console.error: ${args.map(String).join(" ")}`);
    originalError(...args);
  };
});

const page = await context.newPage();
const saves = {};

function stepTimeout(step) {
  return step.timeoutMs || spec.stepTimeoutMs || 30_000;
}

function substitute(value) {
  if (typeof value !== "string") return value;
  return value.replace(/\{\{([\w.]+)\}\}/g, (_match, templatePath) => {
    let current = saves;
    for (const key of templatePath.split(".")) {
      current = current == null ? undefined : current[key];
    }
    if (current === undefined) {
      throw new Error(`template {{${templatePath}}} resolved to nothing`);
    }
    return String(current);
  });
}

function resolveUrl(url) {
  const substituted = substitute(url);
  return /^https?:\/\//.test(substituted) ? substituted : spec.baseUrl + substituted;
}

function checkExpect(expect, value, label) {
  if (expect === undefined || expect === null) return;
  const [[op, target]] = Object.entries(expect);
  let ok;
  switch (op) {
    case "eq":
      ok = value === target || (typeof value === "number" && value == target);
      break;
    case "neq":
      ok = value !== target;
      break;
    case "gt":
      ok = value > target;
      break;
    case "gte":
      ok = value >= target;
      break;
    case "lt":
      ok = value < target;
      break;
    case "lte":
      ok = value <= target;
      break;
    case "truthy":
      ok = Boolean(value);
      break;
    case "falsy":
      ok = !value;
      break;
    default:
      throw new Error(`unknown expect operator ${JSON.stringify(op)}`);
  }
  if (!ok) {
    throw new Error(
      `expect ${op} ${JSON.stringify(target)} failed: got ${JSON.stringify(value)}`
    );
  }
  console.log(`      expect ${op} ${JSON.stringify(target)} -> ${JSON.stringify(value)} (${label})`);
}

async function runStep(step, index, total) {
  const label = step.name || JSON.stringify(step).slice(0, 80);
  console.log(`  [${index + 1}/${total}] ${label} …`);

  if (step.open !== undefined) {
    await page.goto(resolveUrl(step.open), { waitUntil: "load", timeout: stepTimeout(step) });
  } else if (step.waitForSelector !== undefined) {
    const selector =
      typeof step.waitForSelector === "string"
        ? step.waitForSelector
        : step.waitForSelector.selector;
    const state =
      (typeof step.waitForSelector === "object" && step.waitForSelector.state) || "visible";
    await page.waitForSelector(selector, { state, timeout: stepTimeout(step) });
  } else if (step.waitForFunction !== undefined) {
    const fn = new Function(`return (${step.waitForFunction})()`);
    await page.waitForFunction(fn, undefined, { timeout: stepTimeout(step) });
  } else if (step.sleep !== undefined) {
    await page.waitForTimeout(step.sleep);
  } else if (step.evaluate !== undefined) {
    const source = typeof step.evaluate === "string" ? step.evaluate : step.evaluate.body;
    const expect = step.expect || (typeof step.evaluate === "object" ? step.evaluate.expect : undefined);
    const fn = new Function(`return (${source})()`);
    const value = await page.evaluate(fn);
    checkExpect(expect, value, label);
  } else if (step.fetch) {
    const request = step.fetch;
    const value = await page.evaluate(
      async ({ url, method, headers, body }) => {
        const init = { method: method || "GET", credentials: "same-origin" };
        if (headers) init.headers = headers;
        if (body !== undefined) {
          init.body = typeof body === "string" ? body : JSON.stringify(body);
        }
        const response = await fetch(url, init);
        const text = await response.text();
        return { status: response.status, ok: response.ok, text };
      },
      { url: resolveUrl(request.url), method: request.method, headers: request.headers, body: request.body }
    );
    if (!value.ok) {
      throw new Error(
        `fetch ${request.method || "GET"} ${request.url} -> HTTP ${value.status}: ${value.text.slice(0, 300)}`
      );
    }
    let parsed = value.text;
    try {
      parsed = JSON.parse(value.text);
    } catch {
      // keep the raw text for non-JSON responses
    }
    const saveAs = step.saveAs || request.saveAs;
    if (saveAs) saves[saveAs] = parsed;
    console.log(`      fetch ${request.method || "GET"} ${request.url} -> HTTP ${value.status}`);
  } else if (step.click) {
    const selector = typeof step.click === "string" ? step.click : step.click.selector;
    await page.click(selector, { timeout: stepTimeout(step) });
  } else if (step.drag) {
    const drag = step.drag;
    const selector = drag.selector || "#viewport";
    const box = await page.locator(selector).boundingBox();
    if (!box) throw new Error(`drag: ${selector} has no bounding box`);
    const point = (p) =>
      p && p.fx !== undefined
        ? { x: box.x + p.fx * box.width, y: box.y + p.fy * box.height }
        : { x: p.x, y: p.y };
    const from = point(drag.from);
    const to = point(drag.to);
    const steps = drag.steps || 8;
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    for (let i = 1; i <= steps; i++) {
      await page.mouse.move(
        from.x + ((to.x - from.x) * i) / steps,
        from.y + ((to.y - from.y) * i) / steps
      );
    }
    await page.mouse.up();
    if (drag.settleMs) await page.waitForTimeout(drag.settleMs);
  } else if (step.dragImage) {
    // Drag between two *image* coordinates (not page/fraction coordinates).
    // The step computes the viewport's letterbox mapping in-page so a scenario
    // can click a known image point and assert the bone lands exactly there -
    // the click-precision regression the offset report demands.
    const drag = step.dragImage;
    const selector = drag.selector || "#viewport";
    const pts = await page.evaluate(
      ({ selector, from, to, imgW, imgH }) => {
        const el = document.querySelector(selector);
        const r = el.getBoundingClientRect();
        const scale = Math.min(r.width / imgW, r.height / imgH);
        const offsetX = (r.width - imgW * scale) / 2;
        const offsetY = (r.height - imgH * scale) / 2;
        const toClient = ([ix, iy]) => [r.left + offsetX + ix * scale, r.top + offsetY + iy * scale];
        return { from: toClient(from), to: toClient(to) };
      },
      { selector, from: drag.from, to: drag.to, imgW: drag.imgW, imgH: drag.imgH }
    );
    const steps = drag.steps || 8;
    await page.mouse.move(pts.from[0], pts.from[1]);
    await page.mouse.down();
    for (let i = 1; i <= steps; i++) {
      await page.mouse.move(
        pts.from[0] + ((pts.to[0] - pts.from[0]) * i) / steps,
        pts.from[1] + ((pts.to[1] - pts.from[1]) * i) / steps
      );
    }
    await page.mouse.up();
    if (drag.settleMs) await page.waitForTimeout(drag.settleMs);
  } else if (step.dragHandle) {
    // Drag one of the CTA handles (move / rotate) beside the selected bone.
    // The step computes the handle's on-screen centre from the bone's image
    // coordinates and the live canvas transform, then drags it by a
    // `delta` expressed in image pixels - so a scenario can drive the exact
    // pointer path the real handleHit/pointerDown logic follows.
    const dh = step.dragHandle;
    const selector = dh.selector || "#viewport";
    const pts = await page.evaluate(
      ({ selector, handle, head, tail, imgW, delta }) => {
        const el = document.querySelector(selector);
        const canvas = el.querySelector("canvas");
        const cr = canvas.getBoundingClientRect();
        const scale = cr.width / imgW;
        const dxv = tail[0] - head[0];
        const dyv = tail[1] - head[1];
        const len = Math.hypot(dxv, dyv) || 1;
        const ux = dxv / len;
        const uy = dyv / len;
        const offset = 16 / scale;
        const midX = (head[0] + tail[0]) / 2;
        const midY = (head[1] + tail[1]) / 2;
        let cx, cy;
        if (handle === "move") {
          cx = midX - uy * offset;
          cy = midY + ux * offset;
        } else {
          cx = tail[0] + ux * offset;
          cy = tail[1] + uy * offset;
        }
        const from = [cr.left + cx * scale, cr.top + cy * scale];
        const to = [from[0] + delta[0] * scale, from[1] + delta[1] * scale];
        return { from, to };
      },
      { selector, handle: dh.handle, head: dh.head, tail: dh.tail, imgW: dh.imgW, delta: dh.delta }
    );
    const steps = dh.steps || 8;
    await page.mouse.move(pts.from[0], pts.from[1]);
    await page.mouse.down();
    for (let i = 1; i <= steps; i++) {
      await page.mouse.move(
        pts.from[0] + ((pts.to[0] - pts.from[0]) * i) / steps,
        pts.from[1] + ((pts.to[1] - pts.from[1]) * i) / steps
      );
    }
    await page.mouse.up();
    if (dh.settleMs) await page.waitForTimeout(dh.settleMs);
  } else if (step.resize) {
    await page.setViewportSize({ width: step.resize.width, height: step.resize.height });
  } else if (step.screenshot) {
    const shot = step.screenshot;
    fs.mkdirSync(path.dirname(shot.path), { recursive: true });
    const target = shot.selector ? page.locator(shot.selector) : page;
    await target.screenshot({ path: shot.path, timeout: stepTimeout(step) });
    console.log(`      saved ${shot.path}`);
  } else {
    throw new Error(`unknown step shape: ${JSON.stringify(step)}`);
  }

  console.log(`         ok`);
}

let failed = false;
try {
  const steps = spec.steps || [];
  if (!Array.isArray(steps) || steps.length === 0) {
    throw new Error("scenario has no steps");
  }
  for (const [index, step] of steps.entries()) {
    const label = step.name || `step ${index + 1}`;
    try {
      await runStep(step, index, steps.length);
    } catch (error) {
      throw new Error(`${label}: ${error.message}`);
    }
  }
} catch (error) {
  failed = true;
  console.error(`\nFAILED on step: ${error.message}`);
  if (spec.failureScreenshot) {
    try {
      fs.mkdirSync(path.dirname(spec.failureScreenshot), { recursive: true });
      await page.screenshot({ path: spec.failureScreenshot });
      console.error(`failure screenshot saved to ${spec.failureScreenshot}`);
    } catch {
      // the failure screenshot is best-effort
    }
  }
}

await browser.close().catch(() => {});

if (failed) {
  console.error("scenario FAILED");
  process.exit(1);
}

console.log("scenario PASSED");
process.exit(0);
