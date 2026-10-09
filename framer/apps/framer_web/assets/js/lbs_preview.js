// Phoenix LiveView hook: the Framer editor viewport.
//
// Owns the client-side preview. Pointer interaction (create/move/parent bones,
// pose them) runs here at pointer speed; structural changes are pushed to
// LiveView on pointer-up, while pose changes stay local until the user records
// a keyframe.
//
// The preview implements the same fixed-point inverse-LBS as the engine
// (`lbs.mjs`), so what the viewport shows matches the server's final render.
// A WebGL2 pass resamples the backward map; when WebGL2 is unavailable the
// hook falls back to the 2D canvas.

import {
  applyMatrix,
  computeBackwardMap,
  computeDenseWeights,
  computeVertexWeights,
  evaluateBones,
  interpolatePoses,
  remapBilinear,
  skinPoint,
  skinningFields,
} from "./lbs.mjs";

const PROXY_MAX = 512;
const HIT_RADIUS = 9; // display pixels
const SNAP_RADIANS = Math.PI / 12;
const HANDLE_RADIUS = 7; // display pixels: call-to-action handle radius
const HANDLE_OFFSET = 16; // display pixels: handle standoff from the bone

function parsePoint(value) {
  if (!Array.isArray(value)) return [0, 0];
  return [Number(value[0]) || 0, Number(value[1]) || 0];
}

function poseFor(pose, id) {
  const local = (pose && pose[id]) || {};
  return { rot: local.rot || 0, tx: local.tx || 0, ty: local.ty || 0 };
}

function deepPoses(poses) {
  const out = {};
  for (const [id, pose] of Object.entries(poses)) out[id] = { ...pose };
  return out;
}

function distanceToSegment(px, py, ax, ay, bx, by) {
  const vx = bx - ax;
  const vy = by - ay;
  const wx = px - ax;
  const wy = py - ay;
  const segLen2 = vx * vx + vy * vy;
  if (segLen2 <= 1e-12) return Math.hypot(wx, wy);
  const t = Math.max(0, Math.min(1, (wx * vx + wy * vy) / segLen2));
  return Math.hypot(wx - t * vx, wy - t * vy);
}

function scaleRig(rig, scale) {
  return {
    canvas: { width: Math.round(rig.canvas.width * scale), height: Math.round(rig.canvas.height * scale) },
    bones: rig.bones.map((bone) => ({
      id: bone.id,
      parent: bone.parent,
      rest: {
        head: [bone.rest.head[0] * scale, bone.rest.head[1] * scale],
        tail: [bone.rest.tail[0] * scale, bone.rest.tail[1] * scale],
      },
      radius: (bone.radius ?? 10) * scale,
      falloff: bone.falloff || "smooth",
    })),
    bind: rig.bind || {},
  };
}

function scaledWorld(world, scale) {
  return world.map((m) => [m[0], m[1], m[2] * scale, m[3], m[4], m[5] * scale, 0, 0, 1]);
}

export const LbsPreview = {
  mounted() {
    this.rig = null;
    this.sourceImage = null;
    this.sourceUrl = this.el.dataset.sourceUrl;
    this.frame = Number(this.el.dataset.frame || 0);
    this.tool = this.el.dataset.tool || "bones";
    this.selected = this.el.dataset.selected || null;
    this.meshVisible = this.el.dataset.mesh !== "false";
    this.labelsVisible = this.el.dataset.labels === "true";
    this.overrides = {};
    this.drag = null;
    this.hover = null;
    this.view = null;
    this.cache = { bindKey: null, weights: null, proxy: null, vertexWeights: null, vertices: null };
    this.renderKey = null;
    this.gl = null;
    this.glProgram = null;
    this.glFailed = false;
    this.lostCanvas = null;

    this.onContextLost = (event) => this.handleContextLost(event);
    this.onContextRestored = () => this.handleContextRestored();

    this.buildDom();
    this.bindPointer();
    this.loadSource();
    this.setCursor(this.tool === "bones" ? "crosshair" : "default");

    this.handleEvent("rig", ({ rig }) => this.setRig(rig));
    this.handleEvent("clear_overrides", () => {
      this.overrides = {};
      this.invalidate();
      this.draw();
    });

    this.onResize = () => {
      this.measureView();
      this.draw();
    };
    window.addEventListener("resize", this.onResize);

    // Entering or leaving fullscreen resizes the viewport without a window
    // resize on every platform: re-fit both canvases at the current
    // devicePixelRatio, exactly like the resize handler does.
    this.onFullscreenChange = () => {
      this.measureView();
      this.draw();
    };
    document.addEventListener("fullscreenchange", this.onFullscreenChange);
  },

  updated() {
    this.frame = Number(this.el.dataset.frame || 0);
    this.tool = this.el.dataset.tool || "bones";
    this.selected = this.el.dataset.selected || null;
    this.meshVisible = this.el.dataset.mesh !== "false";
    this.labelsVisible = this.el.dataset.labels === "true";

    const url = this.el.dataset.sourceUrl;
    if (url !== this.sourceUrl) {
      this.sourceUrl = url;
      this.sourceImage = null;
      this.invalidate();
      this.loadSource();
      return;
    }

    this.draw();
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize);
    document.removeEventListener("fullscreenchange", this.onFullscreenChange);
    this.unbindCanvasEvents();
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    window.removeEventListener("pointermove", this.onPointerMove);
    window.removeEventListener("pointerup", this.onPointerUp);
    this.releaseGl();
  },

  buildDom() {
    this.el.classList.add("framer-viewport");
    this.surface = this.el.querySelector("#viewport-surface") || this.el;
    this.surface.innerHTML = "";

    this.canvas = document.createElement("canvas");
    this.canvas.className = "framer-viewport-canvas";
    this.overlay = document.createElement("canvas");
    this.overlay.className = "framer-viewport-overlay";
    this.status = document.createElement("div");
    this.status.className = "framer-viewport-status";

    this.surface.append(this.canvas, this.overlay, this.status);
    this.ctx = this.overlay.getContext("2d");
    this.bindCanvasEvents();
  },

  bindPointer() {
    this.onPointerDown = (event) => this.pointerDown(event);
    this.onPointerMove = (event) => this.pointerMove(event);
    this.onPointerUp = (event) => this.pointerUp(event);
    this.el.addEventListener("pointerdown", this.onPointerDown);
    window.addEventListener("pointermove", this.onPointerMove);
    window.addEventListener("pointerup", this.onPointerUp);
  },

  loadSource() {
    const url = this.el.dataset.sourceUrl;
    this.sourceUrl = url;

    if (!url) {
      this.setStatus("Load a still image to begin");
      return;
    }

    const image = new Image();
    image.onload = () => {
      this.sourceImage = image;
      this.setStatus(null);
      this.invalidate();
      this.draw();
    };
    image.onerror = () => this.setStatus("Could not load the source image");
    image.src = url;
  },

  setRig(rig) {
    const previous = this.rig;
    this.rig = rig;
    if (!previous || previous.id !== rig.id) {
      this.overrides = {};
    }
    this.selected = this.el.dataset.selected || null;
    this.invalidate();
    this.draw();
  },

  setStatus(message) {
    this.status.textContent = message || "";
    this.status.style.display = message ? "block" : "none";
  },

  // Set the pointer cursor across the viewport and its canvases. The overlay
  // is pointer-events:none and the image canvas sits above the viewport, so
  // both must follow the hook's chosen cursor for the affordance to show.
  setCursor(cursor) {
    this.el.style.cursor = cursor;
    if (this.canvas) this.canvas.style.cursor = cursor;
    if (this.overlay) this.overlay.style.cursor = cursor;
  },

  invalidate() {
    this.cache.bindKey = null;
    this.renderKey = null;
  },

  measureView() {
    const rect = this.el.getBoundingClientRect();
    if (!this.rig || !rect.width || !rect.height) return;

    const imageWidth = this.rig.canvas.width;
    const imageHeight = this.rig.canvas.height;
    const scale = Math.min(rect.width / imageWidth, rect.height / imageHeight);
    const dispWidth = imageWidth * scale;
    const dispHeight = imageHeight * scale;

    this.view = {
      scale,
      offsetX: (rect.width - dispWidth) / 2,
      offsetY: (rect.height - dispHeight) / 2,
      dispWidth,
      dispHeight,
    };

    const dpr = window.devicePixelRatio || 1;
    for (const canvas of [this.canvas, this.overlay]) {
      canvas.style.width = `${dispWidth}px`;
      canvas.style.height = `${dispHeight}px`;
      canvas.style.left = `${this.view.offsetX}px`;
      canvas.style.top = `${this.view.offsetY}px`;
    }

    this.overlay.width = Math.max(1, Math.round(dispWidth * dpr));
    this.overlay.height = Math.max(1, Math.round(dispHeight * dpr));
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  },

  toImage(event) {
    const rect = this.el.getBoundingClientRect();
    const x = (event.clientX - rect.left - this.view.offsetX) / this.view.scale;
    const y = (event.clientY - rect.top - this.view.offsetY) / this.view.scale;
    return [x, y];
  },

  poses() {
    const poses = this.rig ? interpolatePoses(this.rig, this.frame) : {};
    for (const [id, pose] of Object.entries(this.overrides)) {
      poses[id] = { ...(poses[id] || { rot: 0, tx: 0, ty: 0 }), ...pose };
    }
    return poses;
  },

  ensureCache() {
    if (!this.rig || !this.sourceImage) return false;
    this.measureView();
    if (!this.view) return false;

    const rig = this.rig;
    const bindKey = JSON.stringify({
      canvas: rig.canvas,
      bones: rig.bones.map((b) => [b.id, b.parent, b.rest, b.radius, b.falloff]),
      bind: rig.bind,
    });

    if (bindKey === this.cache.bindKey) return true;

    const baseScale = Math.min(1, PROXY_MAX / Math.max(rig.canvas.width, rig.canvas.height));
    const proxyRig = scaleRig(rig, baseScale);
    const proxy = { width: proxyRig.canvas.width, height: proxyRig.canvas.height, scale: baseScale };
    proxy.source = this.downscale(proxy.width, proxy.height);

    this.cache = {
      bindKey,
      scale: baseScale,
      proxy,
      weights: computeDenseWeights(proxyRig, proxy.width, proxy.height),
      vertices: (rig.mesh && rig.mesh.vertices) || [],
      vertexWeights: null,
    };
    this.cache.vertexWeights = computeVertexWeights(rig, this.cache.vertices);
    this.renderKey = null;
    return true;
  },

  downscale(width, height) {
    const scratch = document.createElement("canvas");
    scratch.width = width;
    scratch.height = height;
    const context = scratch.getContext("2d");
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = "high";
    context.drawImage(this.sourceImage, 0, 0, width, height);
    return context.getImageData(0, 0, width, height);
  },

  draw() {
    if (!this.rig || !this.sourceImage) {
      this.drawOverlay();
      return;
    }

    if (!this.ensureCache()) return;

    const key = `${this.frame}|${this.tool}|${this.selected}|${JSON.stringify(this.overrides)}`;
    if (key !== this.renderKey) {
      this.renderKey = key;
      this.renderScene();
    }

    this.drawOverlay();
  },

  renderScene() {
    const { proxy, weights, scale } = this.cache;
    const poses = this.poses();
    const world = evaluateBones(this.rig, this.frame, poses);
    const proxyWorld = scaledWorld(world, scale);
    const { A, T } = skinningFields(weights, proxyWorld, this.rig.bones.length, proxy.width, proxy.height);

    this.ensureViewportCanvas();
    const iterations = 5;

    if (this.gl) {
      try {
        const { mapX, mapY } = computeBackwardMap(A, T, proxy.width, proxy.height, iterations);
        this.drawWebgl(proxy, mapX, mapY);
        return;
      } catch (error) {
        console.warn("WebGL2 preview failed, falling back to canvas", error);
        this.releaseGl();
      }
    }

    const { mapX, mapY } = computeBackwardMap(A, T, proxy.width, proxy.height, iterations);
    const rgba = remapBilinear(proxy.source.data, proxy.width, proxy.height, mapX, mapY);
    this.drawCanvas(rgba);
  },

  ensureViewportCanvas() {
    const { proxy } = this.cache;
    const sizeMatches =
      this.canvas.width === proxy.width && this.canvas.height === proxy.height;

    if (!sizeMatches && !this.gl && !this.glFailed) {
      this.initGl(proxy.width, proxy.height);
    }

    if (this.gl) {
      if (!sizeMatches) {
        this.canvas.width = proxy.width;
        this.canvas.height = proxy.height;
      }
      return;
    }

    if (!sizeMatches || !this.canvas._is2d) {
      this.canvas.width = proxy.width;
      this.canvas.height = proxy.height;
      this.ctx2d = this.canvas.getContext("2d");
      this.canvas._is2d = true;
    }
  },

  drawCanvas(rgba) {
    const { proxy } = this.cache;
    const image = new ImageData(rgba, proxy.width, proxy.height);
    this.ctx2d.putImageData(image, 0, 0);
    this.canvas.style.imageRendering = "auto";
  },

  initGl(width, height) {
    try {
      const gl = this.canvas.getContext("webgl2", { premultipliedAlpha: false, antialias: false });
      if (!gl) throw new Error("WebGL2 unavailable");

      const program = createProgram(gl);
      this.gl = gl;
      this.glProgram = program;
      this.glLocations = {
        pos: gl.getAttribLocation(program, "a_pos"),
        source: gl.getUniformLocation(program, "u_source"),
        map: gl.getUniformLocation(program, "u_map"),
        size: gl.getUniformLocation(program, "u_size"),
      };

      this.glBuffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this.glBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

      this.glSourceTex = gl.createTexture();
      this.glMapTex = gl.createTexture();

      gl.bindTexture(gl.TEXTURE_2D, this.glSourceTex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

      gl.bindTexture(gl.TEXTURE_2D, this.glMapTex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

      this.canvas.width = width;
      this.canvas.height = height;
    } catch (error) {
      console.warn("WebGL2 preview unavailable", error);
      this.releaseGl();
      this.glFailed = true;
    }
  },

  drawWebgl(proxy, mapX, mapY) {
    const gl = this.gl;
    gl.viewport(0, 0, proxy.width, proxy.height);

    gl.bindTexture(gl.TEXTURE_2D, this.glSourceTex);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA,
      proxy.width,
      proxy.height,
      0,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      new Uint8Array(proxy.source.data.buffer)
    );

    const map = new Float32Array(proxy.width * proxy.height * 2);
    for (let i = 0; i < mapX.length; i++) {
      map[i * 2] = mapX[i];
      map[i * 2 + 1] = mapY[i];
    }

    gl.bindTexture(gl.TEXTURE_2D, this.glMapTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RG32F, proxy.width, proxy.height, 0, gl.RG, gl.FLOAT, map);

    gl.useProgram(this.glProgram);
    gl.uniform1i(this.glLocations.source, 0);
    gl.uniform1i(this.glLocations.map, 1);
    gl.uniform2f(this.glLocations.size, proxy.width, proxy.height);

    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.glSourceTex);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.glMapTex);

    gl.bindBuffer(gl.ARRAY_BUFFER, this.glBuffer);
    gl.enableVertexAttribArray(this.glLocations.pos);
    gl.vertexAttribPointer(this.glLocations.pos, 2, gl.FLOAT, false, 0, 0);

    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  },

  releaseGl() {
    if (this.gl) {
      const gl = this.gl;
      if (this.glBuffer) gl.deleteBuffer(this.glBuffer);
      if (this.glSourceTex) gl.deleteTexture(this.glSourceTex);
      if (this.glMapTex) gl.deleteTexture(this.glMapTex);
      if (this.glProgram) gl.deleteProgram(this.glProgram);
    }
    this.gl = null;
    this.glBuffer = null;
    this.glSourceTex = null;
    this.glMapTex = null;
    this.glProgram = null;
  },

  // --- WebGL context loss / restore ----------------------------------------
  //
  // The image canvas yields either a WebGL2 context (the fast path) or a 2D
  // context (the fallback), never both. A lost WebGL context is terminal for
  // the canvas that held it: its drawing buffer is gone and the element
  // refuses getContext("2d") forever, so the preview swaps in a fresh canvas
  // and keeps the image visible through the 2D fallback. The listeners are
  // bound by the same helper everywhere a canvas is created, so a recreated
  // canvas keeps its context-loss handling.

  bindCanvasEvents() {
    this.canvas.addEventListener("webglcontextlost", this.onContextLost);
    this.canvas.addEventListener("webglcontextrestored", this.onContextRestored);
  },

  unbindCanvasEvents() {
    for (const canvas of [this.canvas, this.lostCanvas]) {
      if (!canvas) continue;
      canvas.removeEventListener("webglcontextlost", this.onContextLost);
      canvas.removeEventListener("webglcontextrestored", this.onContextRestored);
    }
    this.lostCanvas = null;
  },

  // Replace the image canvas with a clean element. The replaced canvas is
  // kept on the hook rather than discarded: its lost WebGL context may still
  // be restored later and must be able to deliver `webglcontextrestored` so
  // the WebGL2 path can come back.
  replaceCanvas() {
    const old = this.canvas;
    const fresh = document.createElement("canvas");
    fresh.className = "framer-viewport-canvas";
    old.replaceWith(fresh);
    this.canvas = fresh;
    this.ctx2d = null;
    this.lostCanvas = old;
    this.bindCanvasEvents();
  },

  handleContextLost(event) {
    event.preventDefault();
    this.releaseGl();
    this.glFailed = true;
    this.replaceCanvas();
    this.invalidate();
    this.draw();
  },

  handleContextRestored() {
    // The restored event fires on the canvas that lost its context (kept as
    // lostCanvas). Its replacement already carries a 2D context, which can
    // never yield WebGL2, so swap in another clean canvas and clear the
    // failed flag: ensureViewportCanvas then re-initialises the WebGL2 path.
    this.unbindCanvasEvents();
    this.glFailed = false;
    this.replaceCanvas();
    this.lostCanvas = null;
    this.invalidate();
    this.draw();
  },

  drawOverlay() {
    if (!this.ctx) return;
    this.measureView();
    const dpr = window.devicePixelRatio || 1;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);

    if (!this.rig || !this.view || !this.cache.vertexWeights) return;

    const scale = this.view.scale;
    const poses = this.rig ? this.poses() : {};
    const world = evaluateBones(this.rig, this.frame, poses);

    if (this.meshVisible) this.drawMesh(world);
    this.drawBones(world);
    this.drawHandles(world);
    this.drawDrag();
  },

  drawMesh(world) {
    const vertices = this.cache.vertices;
    const triangles = (this.rig.mesh && this.rig.mesh.triangles) || [];
    if (!vertices.length || !triangles.length || this.rig.bones.length === 0) return;

    const ctx = this.ctx;
    ctx.save();
    ctx.strokeStyle = "rgba(255, 255, 255, 0.18)";
    ctx.lineWidth = 0.5;

    const projected = vertices.map((vertex, index) =>
      skinPoint(vertex, this.cache.vertexWeights[index], world)
    );

    ctx.beginPath();
    for (const [a, b, c] of triangles) {
      const pa = this.project(projected[a]);
      const pb = this.project(projected[b]);
      const pc = this.project(projected[c]);
      ctx.moveTo(pa[0], pa[1]);
      ctx.lineTo(pb[0], pb[1]);
      ctx.lineTo(pc[0], pc[1]);
    }
    ctx.stroke();
    ctx.restore();
  },

  drawBones(world) {
    const ctx = this.ctx;
    ctx.save();
    ctx.lineCap = "round";

    this.rig.bones.forEach((bone, index) => {
      const head = this.project(applyMatrix(world[index], parsePoint(bone.rest.head)));
      const tail = this.project(applyMatrix(world[index], parsePoint(bone.rest.tail)));
      const selected = bone.id === this.selected;

      ctx.strokeStyle = selected ? "#f59e0b" : "#38bdf8";
      ctx.lineWidth = selected ? 4 : 3;
      ctx.beginPath();
      ctx.moveTo(head[0], head[1]);
      ctx.lineTo(tail[0], tail[1]);
      ctx.stroke();

      // joint
      ctx.fillStyle = selected ? "#fbbf24" : "#e2e8f0";
      ctx.beginPath();
      ctx.arc(head[0], head[1], selected ? 5 : 4, 0, Math.PI * 2);
      ctx.fill();

      if (this.labelsVisible) {
        ctx.fillStyle = "rgba(226, 232, 240, 0.9)";
        ctx.font = "10px sans-serif";
        ctx.fillText(bone.name || bone.id, head[0] + 6, head[1] - 6);
      }

      // influence radius (selected only)
      if (selected) {
        const radius = (bone.radius ?? 10) * this.view.scale;
        ctx.strokeStyle = "rgba(245, 158, 11, 0.5)";
        ctx.lineWidth = 1;
        ctx.setLineDash([4, 4]);
        ctx.beginPath();
        ctx.arc(head[0], head[1], radius, 0, Math.PI * 2);
        ctx.stroke();
        ctx.setLineDash([]);
      }

      // parent link
      if (bone.parent) {
        const parentIndex = this.rig.bones.findIndex((candidate) => candidate.id === bone.parent);
        if (parentIndex >= 0) {
          const parent = this.project(applyMatrix(world[parentIndex], parsePoint(this.rig.bones[parentIndex].rest.tail)));
          ctx.strokeStyle = "rgba(148, 163, 184, 0.6)";
          ctx.lineWidth = 1;
          ctx.setLineDash([3, 3]);
          ctx.beginPath();
          ctx.moveTo(parent[0], parent[1]);
          ctx.lineTo(head[0], head[1]);
          ctx.stroke();
          ctx.setLineDash([]);
        }
      }
    });

    ctx.restore();
  },

  drawHandles(world) {
    const centers = this.handleCenters(world);
    if (!centers) return;

    const move = this.project(centers.move);
    const rotate = this.project(centers.rotate);
    const radius = HANDLE_RADIUS;

    const ctx = this.ctx;
    ctx.save();
    ctx.lineWidth = 1.5;
    ctx.fillStyle = "#fbbf24";
    ctx.strokeStyle = "#f59e0b";

    // Move handle: a filled disc with a cross - drag to translate the bone.
    ctx.beginPath();
    ctx.arc(move[0], move[1], radius, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(move[0] - radius * 0.5, move[1]);
    ctx.lineTo(move[0] + radius * 0.5, move[1]);
    ctx.moveTo(move[0], move[1] - radius * 0.5);
    ctx.lineTo(move[0], move[1] + radius * 0.5);
    ctx.stroke();

    // Rotate handle: a ring - drag to rotate the bone around its head.
    ctx.beginPath();
    ctx.arc(rotate[0], rotate[1], radius, 0, Math.PI * 2);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(rotate[0], rotate[1], 2, 0, Math.PI * 2);
    ctx.fill();

    ctx.restore();
  },

  drawDrag() {
    if (!this.drag || this.drag.type !== "create") return;
    const ctx = this.ctx;
    const head = this.project(this.drag.head);
    const tail = this.project(this.drag.tail);
    ctx.save();
    ctx.strokeStyle = "#22c55e";
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.moveTo(head[0], head[1]);
    ctx.lineTo(tail[0], tail[1]);
    ctx.stroke();
    ctx.restore();
  },

  project(point) {
    return [this.view.offsetX + point[0] * this.view.scale, this.view.offsetY + point[1] * this.view.scale];
  },

  hitTest(point, world) {
    if (!this.rig) return null;
    const [x, y] = point;
    const threshold = HIT_RADIUS / this.view.scale;
    let best = null;

    this.rig.bones.forEach((bone, index) => {
      const head = applyMatrix(world[index], parsePoint(bone.rest.head));
      const tail = applyMatrix(world[index], parsePoint(bone.rest.tail));

      const headDistance = Math.hypot(x - head[0], y - head[1]);
      const tailDistance = Math.hypot(x - tail[0], y - tail[1]);
      const bodyDistance = distanceToSegment(x, y, head[0], head[1], tail[0], tail[1]);

      const consider = (kind, distance) => {
        if (distance <= threshold && (!best || distance < best.distance)) {
          best = { id: bone.id, index, kind, distance };
        }
      };

      consider("head", headDistance);
      consider("tail", tailDistance);
      consider("body", bodyDistance);
    });

    return best;
  },

  // Image-coordinate centres of the two call-to-action handles on the selected
  // bone: a move handle beside the midpoint and a rotate handle just beyond the
  // tail. They are affordances only - dragging them drives the existing
  // translate / rotate / move-tail drag paths, so posing no longer needs a
  // precise grab of a thin joint.
  handleCenters(world) {
    if (!this.rig || !this.selected) return null;
    const index = this.rig.bones.findIndex((bone) => bone.id === this.selected);
    if (index < 0) return null;

    const bone = this.rig.bones[index];
    const head = applyMatrix(world[index], parsePoint(bone.rest.head));
    const tail = applyMatrix(world[index], parsePoint(bone.rest.tail));
    const dx = tail[0] - head[0];
    const dy = tail[1] - head[1];
    const length = Math.hypot(dx, dy) || 1;
    const ux = dx / length;
    const uy = dy / length;
    const offset = HANDLE_OFFSET / this.view.scale;
    const midX = (head[0] + tail[0]) / 2;
    const midY = (head[1] + tail[1]) / 2;

    return {
      index,
      move: [midX - uy * offset, midY + ux * offset],
      rotate: [tail[0] + ux * offset, tail[1] + uy * offset],
    };
  },

  handleHit(point, world) {
    const centers = this.handleCenters(world);
    if (!centers) return null;

    const threshold = (HANDLE_RADIUS + 4) / this.view.scale;
    const [x, y] = point;

    if (Math.hypot(x - centers.move[0], y - centers.move[1]) <= threshold) {
      return { type: "move", id: this.selected, index: centers.index };
    }
    if (Math.hypot(x - centers.rotate[0], y - centers.rotate[1]) <= threshold) {
      return { type: "rotate", id: this.selected, index: centers.index };
    }
    return null;
  },

  // Reflect what is under the cursor: a grab cursor over a handle or the bone
  // body (both drag to translate/rotate), a select cursor over a joint, and a
  // crosshair / default cursor over empty canvas depending on the tool.
  updateHover(event) {
    if (!this.rig || !this.view) return;

    const rect = this.el.getBoundingClientRect();
    const inside =
      event.clientX >= rect.left &&
      event.clientX <= rect.right &&
      event.clientY >= rect.top &&
      event.clientY <= rect.bottom;
    if (!inside) return;

    const point = this.toImage(event);
    const world = evaluateBones(this.rig, this.frame, this.poses());

    if (this.handleHit(point, world)) {
      this.setCursor("grab");
      return;
    }

    const hit = this.hitTest(point, world);
    if (hit) {
      this.setCursor(hit.kind === "body" ? "grab" : "pointer");
      return;
    }

    this.setCursor(this.tool === "bones" ? "crosshair" : "default");
  },

  pointerDown(event) {
    if (event.button !== 0 || !this.rig || !this.view) return;
    event.preventDefault();

    const point = this.toImage(event);
    const world = evaluateBones(this.rig, this.frame, this.poses());

    const handle = this.handleHit(point, world);
    if (handle) {
      this.selectBone(handle.id);
      if (handle.type === "move") {
        if (this.tool === "pose") {
          this.drag = {
            type: "pose",
            id: handle.id,
            start: point,
            initial: poseFor(this.poses(), handle.id),
            mode: "translate",
            head: lastWorldPoint(world, handle.index, this.rig, "head"),
          };
        } else {
          this.drag = {
            type: "translate",
            id: handle.id,
            start: point,
            head: parsePoint(this.rig.bones[handle.index].rest.head),
            tail: parsePoint(this.rig.bones[handle.index].rest.tail),
          };
        }
      } else if (this.tool === "pose") {
        this.drag = {
          type: "pose",
          id: handle.id,
          start: point,
          initial: poseFor(this.poses(), handle.id),
          mode: "rotate",
          head: lastWorldPoint(world, handle.index, this.rig, "head"),
        };
      } else {
        const tail = parsePoint(this.rig.bones[handle.index].rest.tail);
        this.drag = {
          type: "move",
          id: handle.id,
          which: "tail",
          head: parsePoint(this.rig.bones[handle.index].rest.head),
          tail,
          grab: [point[0] - tail[0], point[1] - tail[1]],
        };
      }
      this.setCursor("grabbing");
      this.draw();
      return;
    }

    const hit = this.hitTest(point, world);

    if (this.tool === "pose") {
      if (hit) {
        this.selectBone(hit.id);
        this.drag = {
          type: "pose",
          id: hit.id,
          start: point,
          initial: poseFor(this.poses(), hit.id),
          mode: hit.kind === "body" ? "translate" : "rotate",
          head: lastWorldPoint(world, hit.index, this.rig, "head"),
        };
        this.setCursor("grabbing");
      }
      return;
    }

    // bones tool
    if (hit && hit.kind === "head") {
      this.drag = { type: "move", id: hit.id, which: "head", head: parsePoint(this.rig.bones[hit.index].rest.head), tail: parsePoint(this.rig.bones[hit.index].rest.tail) };
      this.selectBone(hit.id);
    } else if (hit && hit.kind === "tail") {
      this.drag = { type: "move", id: hit.id, which: "tail", head: parsePoint(this.rig.bones[hit.index].rest.head), tail: parsePoint(this.rig.bones[hit.index].rest.tail) };
      this.selectBone(hit.id);
    } else if (hit) {
      this.drag = { type: "translate", id: hit.id, start: point, head: parsePoint(this.rig.bones[hit.index].rest.head), tail: parsePoint(this.rig.bones[hit.index].rest.tail) };
      this.selectBone(hit.id);
    } else {
      const parent = nearestTail(this.rig, world, point, HIT_RADIUS * 2);
      this.drag = { type: "create", head: point, tail: point, parent };
    }

    this.setCursor("grabbing");
    this.draw();
  },

  pointerMove(event) {
    if (!this.drag) {
      this.updateHover(event);
      return;
    }
    const point = this.toImage(event);

    if (this.drag.type === "create") {
      this.drag.tail = snap(point, this.drag.head, event.shiftKey);
    } else if (this.drag.type === "move") {
      const grab = this.drag.grab || [0, 0];
      if (this.drag.which === "head") this.drag.head = [point[0] - grab[0], point[1] - grab[1]];
      else this.drag.tail = [point[0] - grab[0], point[1] - grab[1]];
    } else if (this.drag.type === "translate") {
      this.drag.offset = [point[0] - this.drag.start[0], point[1] - this.drag.start[1]];
    } else if (this.drag.type === "pose") {
      this.applyPoseDrag(point, event);
    }

    this.renderKey = null;
    this.draw();
  },

  applyPoseDrag(point, event) {
    const bone = this.rig.bones.find((candidate) => candidate.id === this.drag.id);
    if (!bone) return;
    const initial = this.drag.initial;

    if (this.drag.mode === "translate") {
      const dx = point[0] - this.drag.start[0];
      const dy = point[1] - this.drag.start[1];
      this.overrides[bone.id] = { ...initial, tx: initial.tx + dx, ty: initial.ty + dy };
    } else {
      const head = this.drag.head;
      const angle = Math.atan2(point[1] - head[1], point[0] - head[0]);
      const restAngle = Math.atan2(bone.rest.tail[1] - bone.rest.head[1], bone.rest.tail[0] - bone.rest.head[0]);
      let rot = angle - restAngle;
      if (event.shiftKey) rot = Math.round(rot / SNAP_RADIANS) * SNAP_RADIANS;
      this.overrides[bone.id] = { ...initial, rot };
    }
  },

  pointerUp() {
    if (!this.drag) return;
    const drag = this.drag;
    this.drag = null;
    this.setCursor(this.tool === "bones" ? "crosshair" : "default");

    if (drag.type === "create") {
      if (Math.hypot(drag.tail[0] - drag.head[0], drag.tail[1] - drag.head[1]) < 2) {
        this.draw();
        return;
      }
      this.pushEvent("bone_created", { head: drag.head, tail: drag.tail, parent: drag.parent });
    } else if (drag.type === "move") {
      this.pushEvent("bone_moved", { id: drag.id, head: drag.head, tail: drag.tail });
    } else if (drag.type === "translate" && drag.offset) {
      this.pushEvent("bone_translated", { id: drag.id, dx: drag.offset[0], dy: drag.offset[1] });
    } else if (drag.type === "pose") {
      this.pushEvent("pose_changed", { pose: deepPoses(this.overrides) });
    }

    this.renderKey = null;
    this.draw();
  },

  selectBone(id) {
    if (this.selected === id) return;
    this.selected = id;
    this.pushEvent("select_bone", { id });
  },
};

export const TimelineScrub = {
  mounted() {
    this.frames = Number(this.el.dataset.frames || 1);
    this.frame = Number(this.el.dataset.frame || 0);
    this.dragging = false;

    this.onPointerDown = (event) => this.start(event);
    this.onPointerMove = (event) => this.move(event);
    this.onPointerUp = () => {
      this.dragging = false;
    };

    this.el.addEventListener("pointerdown", this.onPointerDown);
    window.addEventListener("pointermove", this.onPointerMove);
    window.addEventListener("pointerup", this.onPointerUp);
  },

  updated() {
    this.frames = Number(this.el.dataset.frames || 1);
    this.frame = Number(this.el.dataset.frame || 0);
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    window.removeEventListener("pointermove", this.onPointerMove);
    window.removeEventListener("pointerup", this.onPointerUp);
  },

  start(event) {
    event.preventDefault();
    this.dragging = true;
    this.move(event);
  },

  move(event) {
    if (!this.dragging) return;
    const rect = this.el.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
    const frame = Math.round(ratio * (this.frames - 1));
    if (frame === this.frame) return;
    this.frame = frame;
    this.pushEvent("set_playhead", { frame });
  },
};

export const EditorKeys = {
  mounted() {
    this.onKeyDown = (event) => this.keydown(event);
    window.addEventListener("keydown", this.onKeyDown);
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown);
  },

  keydown(event) {
    const target = event.target || {};
    const tag = target.tagName || "";

    if (["INPUT", "TEXTAREA", "SELECT"].includes(tag) || target.isContentEditable) return;

    if (event.metaKey || event.ctrlKey) {
      if (event.key.toLowerCase() === "z") {
        event.preventDefault();
        this.pushEvent("undo", {});
      }
      return;
    }

    switch (event.key) {
      case " ":
        event.preventDefault();
        this.pushEvent("toggle_play", {});
        break;
      case "k":
      case "K":
        event.preventDefault();
        this.pushEvent("record_keyframe", {});
        break;
      case "ArrowLeft":
        event.preventDefault();
        this.pushEvent("step_frame", { delta: -1 });
        break;
      case "ArrowRight":
        event.preventDefault();
        this.pushEvent("step_frame", { delta: 1 });
        break;
      case "Home":
        event.preventDefault();
        this.pushEvent("set_playhead", { frame: 0 });
        break;
      case "End":
        event.preventDefault();
        this.pushEvent("step_frame", { delta: Number.MAX_SAFE_INTEGER });
        break;
      default:
        break;
    }
  },
};

// --- WebGL helpers ---

const VERTEX_SHADER = `#version 300 es
in vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }
`;

const FRAGMENT_SHADER = `#version 300 es
precision highp float;
uniform sampler2D u_source;
uniform sampler2D u_map;
uniform vec2 u_size;
out vec4 outColor;

vec4 texel(int x, int y) {
  if (x < 0 || y < 0 || x >= int(u_size.x) || y >= int(u_size.y)) return vec4(0.0);
  return texelFetch(u_source, ivec2(x, y), 0);
}

vec4 sampleLinear(vec2 p) {
  float x0 = floor(p.x);
  float y0 = floor(p.y);
  float ax = p.x - x0;
  float ay = p.y - y0;
  int ix = int(x0);
  int iy = int(y0);
  return texel(ix, iy) * (1.0 - ax) * (1.0 - ay)
       + texel(ix + 1, iy) * ax * (1.0 - ay)
       + texel(ix, iy + 1) * (1.0 - ax) * ay
       + texel(ix + 1, iy + 1) * ax * ay;
}

void main() {
  int x = int(floor(gl_FragCoord.x));
  int y = int(u_size.y) - 1 - int(floor(gl_FragCoord.y));
  vec2 p = texelFetch(u_map, ivec2(x, y), 0).xy;
  outColor = sampleLinear(p);
}
`;

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(shader);
    gl.deleteShader(shader);
    throw new Error(`shader compile failed: ${log}`);
  }
  return shader;
}

function createProgram(gl) {
  const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
  const fragment = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER);
  const program = gl.createProgram();
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  gl.deleteShader(vertex);
  gl.deleteShader(fragment);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const log = gl.getProgramInfoLog(program);
    gl.deleteProgram(program);
    throw new Error(`program link failed: ${log}`);
  }
  return program;
}

function lastWorldPoint(world, index, rig, which) {
  return applyMatrix(world[index], parsePoint(rig.bones[index].rest[which]));
}

function nearestTail(rig, world, point, radius) {
  let best = null;
  let bestDistance = radius;
  rig.bones.forEach((bone, index) => {
    const tail = applyMatrix(world[index], parsePoint(bone.rest.tail));
    const distance = Math.hypot(point[0] - tail[0], point[1] - tail[1]);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = bone.id;
    }
  });
  return best;
}

function snap(point, origin, shift) {
  if (!shift) return point;
  const angle = Math.atan2(point[1] - origin[1], point[0] - origin[0]);
  const snapped = Math.round(angle / SNAP_RADIANS) * SNAP_RADIANS;
  const length = Math.hypot(point[0] - origin[0], point[1] - origin[1]);
  return [origin[0] + Math.cos(snapped) * length, origin[1] + Math.sin(snapped) * length];
}
