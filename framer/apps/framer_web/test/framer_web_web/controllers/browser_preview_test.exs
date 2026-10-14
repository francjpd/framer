defmodule FramerWebWeb.BrowserPreviewTest do
  @moduledoc """
  Browser-level proof for the editor preview: scenarios that drive the real
  system Chromium through the repo's Playwright runner
  (`tests/browser/editor_runner.mjs`).

  Why this suite exists: the S1 blank-preview defect and the resize/context
  behaviour are only observable in a real browser, so the end-to-end proof has
  to drive one instead of asserting against server-side DOM. The runner only
  opens pages, performs the scenario steps and saves PNG screenshots of the
  `#viewport` region; every pixel assertion happens here in Elixir. Screenshots
  only, never `readPixels` (a swiftshader artifact makes `readPixels` return
  zeros on a visibly correct canvas).

  Endpoint-in-test resolution (recorded per the slice spec): the suite flips
  the test endpoint's `server:` flag on and restarts it, so the HTTP/WebSocket
  server listens on `127.0.0.1:4002` inside `mix test` — spawning
  `mix phx.server` on a pinned port was not needed. The suite excludes itself
  (`:requires_chromium`) when Chromium, Node or the built editor assets are
  missing (see `test_helper.exs`).
  """

  use ExUnit.Case, async: false

  @moduletag :requires_chromium
  @moduletag timeout: 300_000

  alias FramerWeb.ImageInfo
  alias FramerWebWeb.Fixtures

  @port 4002
  @base_url "http://127.0.0.1:#{@port}"
  @repo_root Path.expand("../../../../../..", __DIR__)
  @browser_dir Path.join(@repo_root, "tests/browser")
  @runner Path.join(@browser_dir, "editor_runner.mjs")

  # The subject block the scenarios paint (a red block on a transparent
  # field, per the slice spec) and the pixel-count thresholds. The preview
  # proxy is capped at 512px so a 64x64 subject is rendered 1:1: the block is
  # 32x32 = 1024 pixels, displayed scaled up in the viewport.
  @subject {255, 0, 0, 255}
  @subject_min 5_000
  # Bone stroke (selected #f59e0b, width 4) and joint (#fbbf24): amber pixels.
  @bone_min 200
  # The rendered overlay must sit on the image point it was created on: window
  # (device px) around the image point the joint disc is collected from, the
  # joint pixel count a 5 CSS px disc gives at DPR 1.5, and how far the disc's
  # centroid may drift from that image point before the overlay counts as
  # displaced. The reported displacement was tens of CSS pixels.
  @alignment_window 30
  @joint_min 80
  @alignment_tolerance 4

  setup_all do
    # Isolate the editor's projects dir exactly like rig_e2e_test.exs, so the
    # browser never reads or writes a developer's real projects.
    original_projects_dir = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_browser_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:framer_web, :projects_dir, root)

    # Boot the endpoint's HTTP server inside `mix test`. The endpoint is
    # already running under the application supervisor with `server: false`;
    # flipping the flag and stopping it makes the one_for_one supervisor
    # restart it with the server listening on the configured test port.
    endpoint_config = Application.get_env(:framer_web, FramerWebWeb.Endpoint)

    Application.put_env(
      :framer_web,
      FramerWebWeb.Endpoint,
      Keyword.put(endpoint_config, :server, true)
    )

    Supervisor.stop(FramerWebWeb.Endpoint)
    wait_until_serving!()

    on_exit(fn ->
      Application.put_env(:framer_web, FramerWebWeb.Endpoint, endpoint_config)
      Supervisor.stop(FramerWebWeb.Endpoint)
      Application.put_env(:framer_web, :projects_dir, original_projects_dir)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "smoke: /editor renders the shell and viewport with zero page errors", %{root: root} do
    shots = Path.join(root, "smoke")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a rig over the API",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-smoke",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(64, 64, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "zero page errors",
          evaluate: "() => window.__framerErrors.length",
          expect: %{eq: 0}
        },
        %{
          name: "screenshot the viewport",
          screenshot: %{path: Path.join(shots, "smoke_viewport.png"), selector: "#viewport"}
        }
      ]
    }

    assert run_scenario(spec, root) == :ok

    # The smoke screenshot must be a real PNG of the viewport region.
    shot = Path.join(shots, "smoke_viewport.png")
    assert %{width: width, height: height} = assert_png!(shot)
    assert width > 0 and height > 0
  end

  test "zero-bone rig: subject visible, then still visible with a bone overlay after a drag",
       %{root: root} do
    shots = Path.join(root, "s1")
    File.mkdir_p!(shots)

    zero_bone = Path.join(shots, "zero_bone.png")
    one_bone = Path.join(shots, "one_bone.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a zero-bone rig",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-s1",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(64, 64, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "screenshot the zero-bone viewport",
          screenshot: %{path: zero_bone, selector: "#viewport"}
        },
        %{
          name: "draw one bone (drag across the viewport)",
          drag: %{
            selector: "#viewport",
            from: %{fx: 0.5, fy: 0.35},
            to: %{fx: 0.5, fy: 0.65},
            steps: 8,
            settleMs: 300
          }
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        %{name: "let the bone overlay draw", sleep: 500},
        %{
          name: "screenshot the one-bone viewport",
          screenshot: %{path: one_bone, selector: "#viewport"}
        }
      ]
    }

    assert run_scenario(spec, root) == :ok

    # The S1 browser-level regression: before slice 1 this screenshot showed
    # zero subject pixels (blank preview); the identity guard makes the
    # zero-bone preview render the source unchanged.
    assert %{width: w0, height: h0} = assert_png!(zero_bone)
    assert subject_pixels(zero_bone, w0, h0) >= @subject_min

    # After the drag: the image must still be visible and the bone overlay
    # must be present.
    assert %{width: w1, height: h1} = assert_png!(one_bone)
    assert subject_pixels(one_bone, w1, h1) >= @subject_min
    assert bone_pixels(one_bone, w1, h1) >= @bone_min
  end

  test "resize regression: bone overlay and subject survive 1280 -> 1600 -> 2000", %{
    root: root
  } do
    shots = Path.join(root, "resize")
    File.mkdir_p!(shots)

    w1280 = Path.join(shots, "w1280.png")
    w1600 = Path.join(shots, "w1600.png")
    w2000 = Path.join(shots, "w2000.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        rig_with_bone_steps("browser-resize") ++
          [
            %{name: "screenshot at 1280px", screenshot: %{path: w1280, selector: "#viewport"}},
            %{name: "resize the viewport to 1600px", resize: %{width: 1600, height: 1000}},
            %{name: "let the preview re-fit", sleep: 500},
            %{name: "screenshot at 1600px", screenshot: %{path: w1600, selector: "#viewport"}},
            %{name: "resize the viewport to 2000px", resize: %{width: 2000, height: 1200}},
            %{name: "let the preview re-fit", sleep: 500},
            %{name: "screenshot at 2000px", screenshot: %{path: w2000, selector: "#viewport"}}
          ]
    }

    assert run_scenario(spec, root) == :ok

    %{width: w1, height: h1} = assert_png!(w1280)
    %{width: w2, height: h2} = assert_png!(w1600)
    %{width: w3, height: h3} = assert_png!(w2000)

    # The audit's demanded regression test for the unconfirmed "bones
    # disappear on resize" report. It stays unconfirmed: the test asserts
    # presence and growth (bone pixels non-decreasing, image present after
    # every resize), not exact counts, so it stays DPR-independent.
    b1 = bone_pixels(w1280, w1, h1)
    b2 = bone_pixels(w1600, w2, h2)
    b3 = bone_pixels(w2000, w3, h3)

    assert b1 >= @bone_min
    assert b2 >= b1
    assert b3 >= b2

    assert subject_pixels(w1280, w1, h1) >= @subject_min
    assert subject_pixels(w1600, w2, h2) >= @subject_min
    assert subject_pixels(w2000, w3, h3) >= @subject_min
  end

  test "context loss: the image survives via the 2D fallback and after restore", %{
    root: root
  } do
    shots = Path.join(root, "ctxloss")
    File.mkdir_p!(shots)

    fallback = Path.join(shots, "fallback.png")
    restored = Path.join(shots, "restored.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        rig_with_bone_steps("browser-ctxloss") ++
          [
            %{
              name: "lose the viewport canvas's WebGL context",
              evaluate:
                "() => { const c = document.querySelector('#viewport canvas'); window.__firstCanvas = c; const gl = c.getContext('webgl2'); window.__lostExt = gl.getExtension('WEBGL_lose_context'); window.__lostExt.loseContext(); return true; }",
              expect: %{eq: true}
            },
            %{
              name: "the hook swaps in a clean canvas",
              waitForFunction:
                "() => document.querySelector('#viewport canvas') !== window.__firstCanvas"
            },
            %{name: "let the 2D fallback settle", sleep: 500},
            %{
              name: "the replacement canvas carries a 2D context, not WebGL2",
              evaluate:
                "() => document.querySelector('#viewport canvas').getContext('webgl2') === null",
              expect: %{eq: true}
            },
            %{
              name: "screenshot the 2D fallback",
              screenshot: %{path: fallback, selector: "#viewport"}
            },
            %{
              name: "restore the lost context",
              evaluate:
                "() => { window.__fallbackCanvas = document.querySelector('#viewport canvas'); window.__lostExt.restoreContext(); return true; }",
              expect: %{eq: true}
            },
            %{
              name: "the hook re-initialises WebGL2 on a fresh canvas",
              waitForFunction:
                "() => document.querySelector('#viewport canvas') !== window.__fallbackCanvas"
            },
            %{name: "let the WebGL2 redraw settle", sleep: 500},
            %{
              name: "the fresh canvas holds a live WebGL2 context",
              evaluate:
                "() => { const gl = document.querySelector('#viewport canvas').getContext('webgl2'); return !!gl && !gl.isContextLost(); }",
              expect: %{eq: true}
            },
            %{
              name: "zero page errors",
              evaluate: "() => window.__framerErrors.length",
              expect: %{eq: 0}
            },
            %{
              name: "screenshot the restored WebGL2 preview",
              screenshot: %{path: restored, selector: "#viewport"}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok

    # The context-loss contract: the image stays visible through the 2D
    # fallback after loseContext(), and again after restoreContext()
    # re-initialises the WebGL2 path; the bone overlay (a separate 2D canvas)
    # is present throughout.
    assert %{width: wf, height: hf} = assert_png!(fallback)
    assert subject_pixels(fallback, wf, hf) >= @subject_min
    assert bone_pixels(fallback, wf, hf) >= @bone_min

    assert %{width: wr, height: hr} = assert_png!(restored)
    assert subject_pixels(restored, wr, hr) >= @subject_min
    assert bone_pixels(restored, wr, hr) >= @bone_min
  end

  test "fullscreen re-measure: the canvas re-fits the container and bones remain", %{
    root: root
  } do
    shots = Path.join(root, "fullscreen")
    File.mkdir_p!(shots)

    after_shot = Path.join(shots, "after_fullscreenchange.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        rig_with_bone_steps("browser-fullscreen") ++
          [
            %{
              name: "fire fullscreenchange and verify the canvas re-fits the container",
              evaluate:
                "async () => { document.dispatchEvent(new Event('fullscreenchange')); await new Promise(r => setTimeout(r, 100)); const c = document.querySelector('#viewport canvas'); const o = document.querySelector('#viewport .framer-viewport-overlay'); const s = document.querySelector('#viewport-surface'); const cr = c.getBoundingClientRect(); const or = o.getBoundingClientRect(); const sr = s.getBoundingClientRect(); const fits = cr.width > 0 && cr.height > 0 && cr.left >= sr.left - 1 && cr.top >= sr.top - 1 && cr.right <= sr.right + 1 && cr.bottom <= sr.bottom + 1; const centered = Math.abs((cr.left - sr.left) - (sr.right - cr.right)) <= 1 && Math.abs((cr.top - sr.top) - (sr.bottom - cr.bottom)) <= 1; const aligned = Math.abs(cr.left - or.left) < 1 && Math.abs(cr.top - or.top) < 1 && Math.abs(cr.width - or.width) < 1 && Math.abs(cr.height - or.height) < 1; return fits && centered && aligned; }",
              expect: %{eq: true}
            },
            %{name: "let the re-fit settle", sleep: 300},
            %{
              name: "screenshot after fullscreenchange",
              screenshot: %{path: after_shot, selector: "#viewport"}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok

    # Headless Chromium makes a real requestFullscreen best-effort, so the
    # reliable assertion is the re-measure effect: the canvas still fits the
    # container (centered and aligned with the overlay) and the bone overlay
    # pixels remain present after the event.
    assert %{width: w, height: h} = assert_png!(after_shot)
    assert subject_pixels(after_shot, w, h) >= @subject_min
    assert bone_pixels(after_shot, w, h) >= @bone_min
  end

  test "click precision: a bone lands where clicked at non-1 DPR and after a fullscreen resize",
       %{root: root} do
    shots = Path.join(root, "precision")
    File.mkdir_p!(shots)

    # A non-square subject exercises the letterboxing the captain's report says
    # the offset depends on; deviceScaleFactor 2 exercises HiDPI. The two
    # dragImage steps click known image points and the evaluate steps assert the
    # created bone lands within tolerance - at DPR 2 and again after a resize
    # (the fullscreen re-measure path, which is what "it moves with fullscreen"
    # exercised).
    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 2,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a non-square rig",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-precision",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(200, 100, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "create a bone from image (100,50) to (140,70)",
          dragImage: %{from: [100, 50], to: [140, 70], imgW: 200, imgH: 100, settleMs: 300}
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        bone_head_error(0, 100, 50),
        %{name: "resize to fullscreen-like dimensions", resize: %{width: 1600, height: 1000}},
        %{name: "let the preview re-fit", sleep: 500},
        %{
          name: "create a second bone from image (40,80) to (80,80)",
          dragImage: %{from: [40, 80], to: [80, 80], imgW: 200, imgH: 100, settleMs: 300}
        },
        %{
          name: "second bone reaches the editor hierarchy",
          waitForFunction:
            "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 2"
        },
        bone_head_error(1, 40, 80)
      ]
    }

    assert run_scenario(spec, root) == :ok
  end

  # The reporter's overlay displacement: a freshly placed bone and its green
  # create-drag preview drew tens of pixels away from the pointer while a DOM
  # marker at the same pointer sat exactly on the cursor, and while the click
  # itself mapped to the right image coordinate. The still is the reporter's own
  # 464x688 portrait at DPR 1.5, so the landscape editor letterboxes it and the
  # letterbox offset that the overlay double-counted is hundreds of device
  # pixels wide. A matching-aspect landscape element does not letterbox, which
  # is why the companion proof reshapes the element instead.
  #
  # Both proofs compare the *drawn* overlay against the rendered image: the red
  # subject block's box centre in the screenshot is where the clicked image point
  # landed, and the selected bone's joint disc must be centred on that same
  # screen position. Comparing stored image coordinates (what the click-precision
  # tests do) cannot see this defect, because the stored data was already right.
  test "overlay alignment: a bone drawn on a letterboxed still sits under the pointer",
       %{root: root} do
    shots = Path.join(root, "overlay_letterbox")
    File.mkdir_p!(shots)
    shot = Path.join(shots, "overlay.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        overlay_align_steps([
          %{
            name: "the portrait still is letterboxed on both sides",
            evaluate:
              "() => { const el = document.querySelector('#viewport'); const r = el.getBoundingClientRect(); const o = el.querySelector('.framer-viewport-overlay').getBoundingClientRect(); return Math.round(o.left - r.left); }",
            expect: %{gt: 20}
          }
        ]) ++
          [
            %{
              name: "screenshot the letterboxed viewport",
              screenshot: %{path: shot, selector: "#viewport"}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok
    assert_overlay_aligned(shot)
  end

  # The companion proof: the same still in an element whose aspect it matches is
  # not letterboxed at all, so the fix must not have moved the overlay the other
  # way. It guards the fix direction - "draw canvas-local" rather than "stop
  # centring the canvases" - which only the unletterboxed case can catch.
  test "overlay alignment: a bone drawn on a non-letterboxed still sits under the pointer",
       %{root: root} do
    shots = Path.join(root, "overlay_aligned")
    File.mkdir_p!(shots)
    shot = Path.join(shots, "overlay.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        overlay_align_steps([]) ++
          [
            %{
              name: "widen the palette until the element's aspect matches the still",
              evaluate:
                "() => { const el = document.querySelector('#viewport'); const p = document.querySelector('#palette'); const r = el.getBoundingClientRect(); const target = (464 / 688) * r.height; p.style.width = Math.round(window.innerWidth - 1 - target) + 'px'; p.style.flexShrink = '0'; return Math.round(target); }",
              expect: %{gt: 0}
            },
            %{name: "let the viewport re-fit", sleep: 500},
            %{
              name: "the still fills the element, so both letterbox offsets are zero",
              evaluate:
                "() => { const el = document.querySelector('#viewport'); const r = el.getBoundingClientRect(); const o = el.querySelector('.framer-viewport-overlay').getBoundingClientRect(); return Math.max(Math.abs(o.left - r.left), Math.abs(o.top - r.top)); }",
              expect: %{lte: 1}
            },
            %{
              name: "screenshot the fitted viewport",
              screenshot: %{path: shot, selector: "#viewport"}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok
    assert_overlay_aligned(shot)
  end

  # The steps both overlay-alignment proofs share: open the octopus-sized
  # portrait still, run `prepare` (the proof's own viewport-shape step, which
  # must land before the drag), then create a bone whose head is the still's
  # exact centre - image (232, 344), where `png_with_subject` centres its red
  # subject block. The click is a real pointer drag, so the bone's head is the
  # image point the pointer actually pressed. Each proof appends its own
  # screenshot step.
  defp overlay_align_steps(prepare) do
    [
      %{name: "open the editor shell", open: "/editor"},
      %{name: "shell renders", waitForSelector: "#editor-shell"},
      %{
        name: "create the 464x688 portrait still",
        fetch: %{
          url: "/api/rigs",
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: %{
            "name" => "browser-overlay-align",
            "filename" => "subject.png",
            "source_base64" => Base.encode64(Fixtures.png_with_subject(464, 688, @subject))
          }
        },
        saveAs: "create"
      },
      %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
      %{name: "viewport renders", waitForSelector: "#viewport"},
      %{
        name: "source image drawn",
        waitForFunction:
          "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
      },
      %{name: "let the preview settle", sleep: 1_000},
      %{
        name: "the overlay canvas sits exactly on the image canvas",
        evaluate:
          "() => { const el = document.querySelector('#viewport'); const c = el.querySelector('canvas').getBoundingClientRect(); const o = el.querySelector('.framer-viewport-overlay').getBoundingClientRect(); return Math.abs(c.left - o.left) < 1 && Math.abs(c.top - o.top) < 1 && Math.abs(c.width - o.width) < 1 && Math.abs(c.height - o.height) < 1; }",
        expect: %{eq: true}
      }
    ] ++
      prepare ++
      [
        %{
          name: "create a bone whose head is the still's centre, image (232,344)",
          dragImage: %{
            from: [232, 344],
            to: [282, 344],
            imgW: 464,
            imgH: 688,
            steps: 8,
            settleMs: 300
          }
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        %{name: "let the bone overlay draw", sleep: 500}
      ]
  end

  # Asserts the drawn bone sits under the image point the pointer is over - the
  # *drawn* overlay compared against the rendered image. The red subject block is
  # the only saturated red in the viewport, so its box centre in the screenshot
  # is the on-screen position of the image point the pointer is over; the
  # selected bone's joint disc (`#fbbf24`, the light amber the hook fills its
  # joints with, lighter than the `#f59e0b` stroke) must be centred on that same
  # screen position. Comparing stored image coordinates (what the
  # click-precision tests do) cannot see these defects, because the stored data
  # was already right. `stage` is `:placed` for a bone drawn where it was
  # created and `:dragging` for a joint following a pointer that is still down.
  # Tolerances are device pixels: 1 CSS px is 1.5 device px at DPR 1.5, and the
  # centring error is dominated by Playwright's rounded element-screenshot origin.
  defp assert_overlay_aligned(shot, stage \\ :placed) do
    assert %{width: width, height: height} = assert_png!(shot)
    assert subject_pixels(shot, width, height) >= @subject_min

    {image_x, image_y, joint_count, joint_x, joint_y} =
      alignment_scan(shot, width, height, @alignment_window)

    assert image_x, "the still's red subject block must be visible in the viewport"
    assert joint_count >= @joint_min, joint_missing_message(stage, image_x, image_y)

    drift = :math.sqrt((joint_x - image_x) ** 2 + (joint_y - image_y) ** 2)

    assert drift <= @alignment_tolerance,
           joint_drift_message(stage, drift, image_x, image_y, joint_x, joint_y)
  end

  defp joint_missing_message(:placed, _image_x, _image_y) do
    "the selected bone's joint disc is not drawn where the pointer placed the bone"
  end

  defp joint_missing_message(:dragging, image_x, image_y) do
    "no joint disc was drawn at the pointer mid-drag: the bone did not follow the pointer " <>
      "(the still's centre is at #{image_x},#{image_y} in device px)"
  end

  defp joint_drift_message(:placed, drift, image_x, image_y, joint_x, joint_y) do
    "the bone's joint drifted #{Float.round(drift, 1)} device px from the image point " <>
      "it was created on (image point at #{image_x},#{image_y}, joint at " <>
      "#{Float.round(joint_x, 1)},#{Float.round(joint_y, 1)})"
  end

  defp joint_drift_message(:dragging, drift, image_x, image_y, joint_x, joint_y) do
    "the drawn joint drifted #{Float.round(drift, 1)} device px from the pointer while the " <>
      "drag was still in progress (pointer image point at #{image_x},#{image_y}, joint at " <>
      "#{Float.round(joint_x, 1)},#{Float.round(joint_y, 1)})"
  end

  test "element resize without a window resize: a click still lands where placed", %{
    root: root
  } do
    shots = Path.join(root, "element_resize")
    File.mkdir_p!(shots)

    # The captain's offset: the viewport ELEMENT can change size while the
    # window does not (a pane or sidebar growing inside the three-pane shell,
    # or a tiled WM narrowing the page). Without a ResizeObserver the
    # canvas-to-image mapping goes stale and the next click lands at an offset.
    # Widening the palette shrinks #viewport with no window resize event, so a
    # bone drawn afterwards only lands correctly if the hook re-measured the
    # element. deviceScaleFactor 1.5 matches the captain's display scaling.
    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a non-square rig",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-element-resize",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(200, 100, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "create a bone from image (100,50) to (140,70)",
          dragImage: %{from: [100, 50], to: [140, 70], imgW: 200, imgH: 100, settleMs: 300}
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        bone_head_error(0, 100, 50),
        %{
          name: "widen the palette so #viewport shrinks with no window resize",
          evaluate:
            "() => { const vp = document.querySelector('#viewport'); const before = vp.getBoundingClientRect().width; const p = document.querySelector('#palette'); p.style.width = '512px'; p.style.flexShrink = '0'; return before - vp.getBoundingClientRect().width; }",
          expect: %{gt: 100}
        },
        %{name: "let the re-measure settle", sleep: 500},
        %{
          name: "create a second bone from image (40,80) to (80,80)",
          dragImage: %{from: [40, 80], to: [80, 80], imgW: 200, imgH: 100, settleMs: 300}
        },
        %{
          name: "second bone reaches the editor hierarchy",
          waitForFunction:
            "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 2"
        },
        bone_head_error(1, 40, 80),
        %{name: "let the bone overlay draw", sleep: 500},
        %{
          name: "screenshot the resized viewport",
          screenshot: %{path: Path.join(shots, "element_resize.png"), selector: "#viewport"}
        }
      ]
    }

    assert run_scenario(spec, root) == :ok

    # Both the subject and the bone overlay must be present after the
    # element-only resize: the image survives and the overlay draws at the
    # re-measured position.
    assert %{width: w, height: h} = assert_png!(Path.join(shots, "element_resize.png"))
    assert subject_pixels(Path.join(shots, "element_resize.png"), w, h) >= @subject_min
    assert bone_pixels(Path.join(shots, "element_resize.png"), w, h) >= @bone_min
  end

  test "fullscreen entry: overlay renders and a click still lands where placed", %{
    root: root
  } do
    shots = Path.join(root, "fullscreen_entry")
    File.mkdir_p!(shots)

    # The captain's fullscreen report: entering fullscreen must re-fit the
    # canvases and keep drawing the bone overlay, and a click must still land
    # where it was placed. requestFullscreen is the real API (not a synthetic
    # event) and fires the fullscreenchange handler the hook listens to.
    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a non-square rig",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-fullscreen-entry",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(200, 100, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "create a bone from image (100,50) to (140,70)",
          dragImage: %{from: [100, 50], to: [140, 70], imgW: 200, imgH: 100, settleMs: 300}
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        bone_head_error(0, 100, 50),
        %{
          name: "enter fullscreen and verify the canvas re-fits the container",
          evaluate:
            "async () => { try { await document.documentElement.requestFullscreen(); } catch (e) {} if (!document.fullscreenElement) { document.dispatchEvent(new Event('fullscreenchange')); } await new Promise(r => setTimeout(r, 300)); const c = document.querySelector('#viewport canvas'); const o = document.querySelector('#viewport .framer-viewport-overlay'); const s = document.querySelector('#viewport-surface'); const cr = c.getBoundingClientRect(); const or = o.getBoundingClientRect(); const sr = s.getBoundingClientRect(); const fits = cr.width > 0 && cr.height > 0 && cr.left >= sr.left - 1 && cr.top >= sr.top - 1 && cr.right <= sr.right + 1 && cr.bottom <= sr.bottom + 1; const centered = Math.abs((cr.left - sr.left) - (sr.right - cr.right)) <= 1 && Math.abs((cr.top - sr.top) - (sr.bottom - cr.bottom)) <= 1; const aligned = Math.abs(cr.left - or.left) < 1 && Math.abs(cr.top - or.top) < 1 && Math.abs(cr.width - or.width) < 1 && Math.abs(cr.height - or.height) < 1; return fits && centered && aligned; }",
          expect: %{eq: true}
        },
        %{
          name: "create a second bone from image (40,80) to (80,80) after fullscreen",
          dragImage: %{from: [40, 80], to: [80, 80], imgW: 200, imgH: 100, settleMs: 300}
        },
        %{
          name: "second bone reaches the editor hierarchy",
          waitForFunction:
            "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 2"
        },
        bone_head_error(1, 40, 80),
        %{name: "let the bone overlay draw", sleep: 500},
        %{
          name: "screenshot the fullscreen viewport",
          screenshot: %{path: Path.join(shots, "fullscreen_entry.png"), selector: "#viewport"}
        }
      ]
    }

    assert run_scenario(spec, root) == :ok

    # The bone/mesh overlay must still render in fullscreen and the subject
    # image must survive the fullscreen transition.
    assert %{width: w, height: h} = assert_png!(Path.join(shots, "fullscreen_entry.png"))
    assert subject_pixels(Path.join(shots, "fullscreen_entry.png"), w, h) >= @subject_min
    assert bone_pixels(Path.join(shots, "fullscreen_entry.png"), w, h) >= @bone_min
  end

  test "EXIF orientation: a rotated photograph still places a bone under the pointer", %{
    root: root
  } do
    shots = Path.join(root, "exif")
    File.mkdir_p!(shots)

    # Each config is a raw landscape still tagged orientation 6 (rotate 90 CW),
    # so the browser and the editor display it as a portrait. The two raw
    # aspect ratios (2:1 and 3:1) exercise the size dependence of the
    # letterboxing without any third-party image content.
    configs = [
      %{raw_w: 400, raw_h: 200, w: 200, h: 400, x: 100, y: 200},
      %{raw_w: 600, raw_h: 200, w: 200, h: 600, x: 100, y: 300}
    ]

    for {config, index} <- Enum.with_index(configs) do
      exif_jpeg = Fixtures.jpeg_with_orientation(config.raw_w, config.raw_h, 6)

      spec = %{
        baseUrl: @base_url,
        viewport: %{width: 1280, height: 900},
        deviceScaleFactor: 1.5,
        failureScreenshot: Path.join(shots, "failure_#{index}.png"),
        steps: [
          %{name: "open the editor shell", open: "/editor"},
          %{name: "shell renders", waitForSelector: "#editor-shell"},
          %{
            name: "create a rig from an EXIF-rotated JPEG",
            fetch: %{
              url: "/api/rigs",
              method: "POST",
              headers: %{"content-type" => "application/json"},
              body: %{
                "name" => "browser-exif-#{index}",
                "filename" => "subject.jpg",
                "source_base64" => Base.encode64(exif_jpeg)
              }
            },
            saveAs: "create"
          },
          %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
          %{name: "viewport renders", waitForSelector: "#viewport"},
          %{
            name: "source image drawn",
            waitForFunction:
              "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
          },
          %{name: "let the preview settle", sleep: 1_000},
          %{
            name: "the rig canvas reports the oriented dimensions",
            evaluate:
              "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return rig.canvas.width + 'x' + rig.canvas.height; }",
            expect: %{eq: "#{config.w}x#{config.h}"}
          },
          %{
            name:
              "create a bone from oriented image (#{config.x},#{config.y}) to (#{config.x + 40},#{config.y})",
            dragImage: %{
              from: [config.x, config.y],
              to: [config.x + 40, config.y],
              imgW: config.w,
              imgH: config.h,
              settleMs: 300
            }
          },
          %{
            name: "bone reaches the editor hierarchy",
            waitForSelector: "button[phx-click=\"select_bone\"]"
          },
          bone_head_error(0, config.x, config.y)
        ]
      }

      assert run_scenario(spec, root) == :ok
    end
  end

  test "pose tool: the move handle poses instead of mutating rest geometry", %{root: root} do
    shots = Path.join(root, "handle_pose")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a rig",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-handle-pose",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(600, 600, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "create a bone from image (300,300) to (420,300)",
          dragImage: %{from: [300, 300], to: [420, 300], imgW: 600, imgH: 600, settleMs: 300}
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        %{
          name: "switch to the pose tool",
          click: %{selector: "button[phx-click=\"select_tool\"][phx-value-tool=\"pose\"]"}
        },
        %{name: "let the tool switch settle", sleep: 300},
        %{
          name: "drag the move handle by (30,0) image px",
          dragHandle: %{
            handle: "move",
            head: [300, 300],
            tail: [420, 300],
            imgW: 600,
            delta: [30, 0],
            settleMs: 300
          }
        },
        %{
          name: "a pose becomes pending (not a structural edit)",
          waitForFunction: "() => document.body.textContent.includes('pose pending')"
        },
        bone_joint_error(0, "head", 300, 300),
        bone_joint_error(0, "tail", 420, 300)
      ]
    }

    assert run_scenario(spec, root) == :ok
  end

  test "bones tool: the rotate handle drags the tail without a start jump", %{root: root} do
    shots = Path.join(root, "handle_rotate")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a rig",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-handle-rotate",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(600, 600, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "create a bone from image (300,300) to (420,300)",
          dragImage: %{from: [300, 300], to: [420, 300], imgW: 600, imgH: 600, settleMs: 300}
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        %{
          name: "nudge the rotate handle by (6,0) image px",
          dragHandle: %{
            handle: "rotate",
            head: [300, 300],
            tail: [420, 300],
            imgW: 600,
            delta: [6, 0],
            settleMs: 300
          }
        },
        # The tail must move by the nudge (6px), not snap to the handle that sits
        # HANDLE_OFFSET/scale beyond it: assert it landed at rest + delta.
        bone_joint_error(0, "tail", 426, 300)
      ]
    }

    assert run_scenario(spec, root) == :ok
  end

  # The captain's drag feedback: dragging an already-placed bone moved it only
  # on release - for the whole drag the bone sat at its old position and jumped
  # on drop. Both proofs press a placed bone, hold the pointer mid-drag and read
  # the *drawn* overlay before any release: the joint must already sit under the
  # pointer while the server still holds the pre-drag rest, and the release must
  # land the bone exactly where it was shown. The still's red subject block is
  # centred on image (100,100), so the screenshot of the viewport shows where
  # the dragged joint sits relative to that point (the same drawn-vs-stored
  # comparison the overlay-alignment proofs use, because the stored rig is
  # still the pre-drag one mid-drag).
  test "bones tool: an in-progress head drag draws the joint under the pointer before release",
       %{root: root} do
    shots = Path.join(root, "drag_head")
    File.mkdir_p!(shots)
    mid = Path.join(shots, "mid_drag.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        live_drag_steps(%{
          name: "browser-drag-head",
          shot: mid,
          press_at: [59, 100],
          press_label: "head joint",
          move_to: [100, 100],
          landed_head: [100, 100],
          landed_tail: [140, 100]
        })
    }

    assert run_scenario(spec, root) == :ok
    assert_overlay_aligned(mid, :dragging)
  end

  # The same proof for the whole-bone translate drag: pressing the bone body
  # and dragging it by (+40,0) must draw the bone (its joint included) 40px to
  # the right live, and release into exactly that position.
  test "bones tool: an in-progress translate drag draws the joint under the pointer before release",
       %{root: root} do
    shots = Path.join(root, "drag_translate")
    File.mkdir_p!(shots)
    mid = Path.join(shots, "mid_drag.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        live_drag_steps(%{
          name: "browser-drag-translate",
          shot: mid,
          press_at: [80, 100],
          press_label: "bone body",
          move_to: [120, 100],
          landed_head: [100, 100],
          landed_tail: [180, 100]
        })
    }

    assert run_scenario(spec, root) == :ok
    assert_overlay_aligned(mid, :dragging)
  end

  # The held-release window: while the released drag is held until `setRig`
  # confirms the pushed rig, a second press must read the same world the overlay
  # draws. The proof translates the whole bone +40 image px, then - inside the
  # window - presses the drawn body where the committed body no longer is, and
  # hold-drags it on. The overlay must hold the dropped pose through the release
  # (no rest-pose frame), the press must hit the drawn bone instead of falling
  # through to the create path, and the release must commit the second edit on
  # top of the first one instead of reverting it. A press that commits nothing
  # (empty canvas) must leave the same pose drawn for the rest of the window.
  test "bones tool: a press inside the held-release window hits the drawn bone and commits on top of it",
       %{root: root} do
    shots = Path.join(root, "held_release")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps: [
        %{name: "open the editor shell", open: "/editor"},
        %{name: "shell renders", waitForSelector: "#editor-shell"},
        %{
          name: "create a rig whose subject block is centred on image (100,100)",
          fetch: %{
            url: "/api/rigs",
            method: "POST",
            headers: %{"content-type" => "application/json"},
            body: %{
              "name" => "browser-held-release",
              "filename" => "subject.png",
              "source_base64" => Base.encode64(Fixtures.png_with_subject(200, 200, @subject))
            }
          },
          saveAs: "create"
        },
        %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
        %{name: "viewport renders", waitForSelector: "#viewport"},
        %{
          name: "source image drawn",
          waitForFunction:
            "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
        },
        %{name: "let the preview settle", sleep: 1_000},
        %{
          name: "create a bone from image (60,100) to (140,100)",
          dragImage: %{from: [60, 100], to: [140, 100], imgW: 200, imgH: 200, settleMs: 300}
        },
        %{
          name: "bone reaches the editor hierarchy",
          waitForSelector: "button[phx-click=\"select_bone\"]"
        },
        %{name: "let the bone overlay draw", sleep: 500},
        # First drag: translate the whole bone by (+40,0). The drawn bone now
        # spans image (100,100)-(180,100) while the committed rest still spans
        # (60,100)-(140,100).
        %{
          name: "press the bone body at image (80,100)",
          pointerDown: %{at: [80, 100], imgW: 200, imgH: 200}
        },
        %{
          name: "move the pointer to the still's centre",
          pointerMove: %{at: [120, 100], imgW: 200, imgH: 200}
        },
        # The whole window in one in-page turn: the release, the second press
        # on the drawn body, the hold-drag and the observations must all happen
        # before the server's rig push can land and rebase the rig. Each step
        # of it records its measurement on `window` for the assertions below.
        %{
          name: "release, press the drawn body and hold-drag - all inside the window",
          evaluate:
            "() => { const vp = document.querySelector('#viewport'); const overlay = vp.querySelector('canvas.framer-viewport-overlay'); const rect = overlay.getBoundingClientRect(); const scale = rect.width / 200; const dpr = window.devicePixelRatio || 1; const at = (ix, iy) => [rect.left + ix * scale, rect.top + iy * scale]; const ctx = overlay.getContext('2d'); const fire = (type, ix, iy) => { const [x, y] = at(ix, iy); window.dispatchEvent(new PointerEvent(type, { clientX: x, clientY: y, bubbles: true })); }; const press = (ix, iy) => { const [x, y] = at(ix, iy); vp.dispatchEvent(new PointerEvent('pointerdown', { clientX: x, clientY: y, button: 0, bubbles: true })); }; const jointDrift = (ix, iy) => { const tx = ix * scale * dpr, ty = iy * scale * dpr; const data = ctx.getImageData(0, 0, overlay.width, overlay.height).data; let sx = 0, sy = 0, n = 0; for (let y = 0; y < overlay.height; y++) { for (let x = 0; x < overlay.width; x++) { const i = (y * overlay.width + x) * 4; if (data[i] >= 200 && data[i + 1] >= 175 && data[i + 2] <= 120 && data[i + 3] >= 200 && Math.hypot(x - tx, y - ty) <= #{@alignment_window}) { sx += x; sy += y; n++; } } } if (n < #{@joint_min}) return 999999; return Math.hypot(sx / n - tx, sy / n - ty); }; const greenNear = (ix, iy) => { const tx = ix * scale * dpr, ty = iy * scale * dpr; const data = ctx.getImageData(0, 0, overlay.width, overlay.height).data; let green = 0; for (let i = 0; i < data.length; i += 4) { const p = i / 4; const x = p % overlay.width; const y = (p - x) / overlay.width; if (data[i] <= 60 && data[i + 1] >= 170 && data[i + 2] <= 120 && data[i + 3] >= 200 && Math.hypot(x - tx, y - ty) <= #{@alignment_window}) green++; } return green; }; fire('pointerup', 120, 100); const afterRelease = jointDrift(100, 100); press(160, 100); fire('pointermove', 180, 100); const createBand = greenNear(170, 100); const afterSecondDrag = jointDrift(120, 100); fire('pointerup', 180, 100); press(10, 10); const duringIdlePress = jointDrift(120, 100); fire('pointerup', 10, 10); const afterIdlePress = jointDrift(120, 100); window.__heldRelease = { release: afterRelease, createBand: createBand, secondDrag: afterSecondDrag, idlePress: duringIdlePress, idleRelease: afterIdlePress }; return true; }"
        },
        # The release draw keeps the dropped pose: the joint stays on the head
        # the first drag dropped, with no rest-pose frame in between.
        %{
          name: "the released draw holds the dropped joint (no rest-pose frame)",
          evaluate: "() => window.__heldRelease.release",
          expect: %{lt: @alignment_tolerance}
        },
        # Pressing the drawn body must not become a create drag: the green
        # rubber band is only ever drawn for one, so none may appear.
        %{
          name: "pressing the drawn body started no create drag",
          evaluate: "() => window.__heldRelease.createBand",
          expect: %{lt: @joint_min}
        },
        # The second drag is seeded from the drawn bone, so the joint follows it
        # instead of snapping back to the committed rest at (60,100).
        %{
          name: "the second drag draws from the drawn bone, not the committed rest",
          evaluate: "() => window.__heldRelease.secondDrag",
          expect: %{lt: @alignment_tolerance}
        },
        # A press that commits nothing - empty canvas, no drag - must not drop
        # the held pose either: the bone stays drawn where the release left it,
        # while the server still holds the pre-drag rest, both during that
        # gesture and after it ends, instead of flashing back to the stored rest
        # for the rest of the round trip.
        %{
          name: "a press that commits nothing keeps the dropped pose drawn",
          evaluate: "() => window.__heldRelease.idlePress",
          expect: %{lt: @alignment_tolerance}
        },
        %{
          name: "the dropped pose outlives the press that commits nothing",
          evaluate: "() => window.__heldRelease.idleRelease",
          expect: %{lt: @alignment_tolerance}
        },
        %{name: "finish the release and let the commits settle", pointerUp: %{settleMs: 300}},
        %{name: "let both rig round trips settle", sleep: 1_000},
        # Both edits are on the document: the bone sits where the second drag
        # drew it, and nothing extra was created.
        bone_joint_error(0, "head", 120, 100),
        bone_joint_error(0, "tail", 200, 100),
        %{
          name: "the document holds exactly one bone",
          evaluate:
            "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return rig.bones.length; }",
          expect: %{eq: 1}
        }
      ]
    }

    assert run_scenario(spec, root) == :ok
  end

  # Zoom proof: the viewport zooms via Ctrl/Cmd+wheel and the in/out/fit
  # controls, and the one pointer-to-image mapping the hook keeps exact holds at
  # every zoom - a bone created at a known image point after a zoom lands under
  # the pointer (its stored head is that image point). The still is far larger
  # than the element so the contain-fit is well below 1:1, leaving room to zoom
  # in toward the native pixels.
  test "zoom: ctrl+wheel and the controls rescale the still and keep the pointer mapping exact",
       %{root: root} do
    shots = Path.join(root, "zoom")
    File.mkdir_p!(shots)

    subj_fit = Path.join(shots, "zoom_fit.png")
    subj_zoomed = Path.join(shots, "zoom_in.png")

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      deviceScaleFactor: 1.5,
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        zoom_steps("browser-zoom") ++
          [
            # Place one bone at the contain-fit first: it selects the bone, which
            # reveals the timeline graph. Waiting for the graph means the
            # viewport element has reached its final height, so the fit baseline
            # recorded next is stable for the whole scenario. This is also the
            # fit-zoom mapping proof.
            %{
              name: "create a bone from image (400,300) to (500,300) at the contain-fit",
              dragImage: %{
                from: [400, 300],
                to: [500, 300],
                imgW: 2000,
                imgH: 1400,
                settleMs: 300
              }
            },
            %{
              name: "bone reaches the editor hierarchy",
              waitForSelector: "button[phx-click=\"select_bone\"]"
            },
            %{
              name: "the timeline graph appears (element is now at its final height)",
              waitForSelector: "button[phx-value-channel=\"rot\"]"
            },
            bone_head_error(0, 400, 300),
            %{name: "let the re-fit settle", sleep: 300},
            %{
              name: "record the contain-fit still size and confirm it fits the element",
              evaluate:
                "() => { const el = document.querySelector('#viewport'); const r = el.getBoundingClientRect(); const o = el.querySelector('.framer-viewport-overlay').getBoundingClientRect(); window.__zoomFitW = o.width; return o.width <= r.width + 2 && o.height <= r.height + 2; }",
              expect: %{eq: true}
            },
            %{
              name: "screenshot the contain-fit still",
              screenshot: %{path: subj_fit, selector: "#viewport"}
            },
            # A plain wheel is NOT the zoom shortcut: only Ctrl/Cmd+wheel zooms.
            %{
              name: "plain wheel over the viewport",
              wheel: %{ctrlKey: false, deltaY: -120, settleMs: 200}
            },
            %{
              name: "a plain wheel leaves the scale at fit",
              evaluate:
                "() => { const c = document.querySelector('#viewport .framer-viewport-overlay').getBoundingClientRect(); return Math.abs(c.width - window.__zoomFitW) < 1; }",
              expect: %{eq: true}
            },
            # Ctrl/Cmd+wheel toward the pointer: one notch zooms the still in.
            # The handler applies the zoom synchronously (it resizes the canvas
            # before it returns), so the scale is already up the instant the
            # dispatch resolves - a direct read is both correct and robust.
            %{
              name: "ctrl+wheel zoom in at the centre",
              wheel: %{at: %{fx: 0.5, fy: 0.5}, deltaY: -100, settleMs: 250}
            },
            %{
              name: "the rendered still is scaled up past the fit",
              evaluate:
                "() => document.querySelector('#viewport .framer-viewport-overlay').getBoundingClientRect().width > window.__zoomFitW * 1.05",
              expect: %{eq: true}
            },
            # The killer assertion: after the wheel zoom a bone created at a
            # known OFF-centre image point lands exactly there, so the one
            # pointer-to-image mapping survived the zoom.
            %{
              name: "create a bone from image (600,520) to (700,520) while zoomed",
              dragImage: %{
                from: [600, 520],
                to: [700, 520],
                imgW: 2000,
                imgH: 1400,
                settleMs: 300
              }
            },
            %{
              name: "second bone reaches the editor hierarchy",
              waitForFunction:
                "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 2"
            },
            bone_head_error(1, 600, 520),
            %{
              name: "screenshot the zoomed still",
              screenshot: %{path: subj_zoomed, selector: "#viewport"}
            },
            # The Fit control returns to the contain-fit from any zoom.
            %{
              name: "click Fit",
              click: %{selector: "button[phx-click=\"zoom\"][phx-value-action=\"fit\"]"}
            },
            %{
              name: "Fit restores the contain-fit scale",
              waitForFunction:
                "() => { const c = document.querySelector('#viewport .framer-viewport-overlay').getBoundingClientRect(); return Math.abs(c.width - window.__zoomFitW) < 2; }"
            },
            # The in/out controls bound the zoom: one step up from the fit, then
            # back to the floor (never below the fit).
            %{
              name: "click zoom in",
              click: %{selector: "button[phx-click=\"zoom\"][phx-value-action=\"in\"]"}
            },
            %{
              name: "the in-control scales the still up",
              waitForFunction:
                "() => { const c = document.querySelector('#viewport .framer-viewport-overlay').getBoundingClientRect(); return c.width > window.__zoomFitW * 1.05; }"
            },
            %{
              name: "record the zoomed width for the out-control floor check",
              evaluate:
                "() => { window.__zoomOutBase = document.querySelector('#viewport .framer-viewport-overlay').getBoundingClientRect().width; return true; }",
              expect: %{truthy: true}
            },
            %{
              name: "click zoom out",
              click: %{selector: "button[phx-click=\"zoom\"][phx-value-action=\"out\"]"}
            },
            %{
              name: "the out-control returns to the fit floor without going below it",
              waitForFunction:
                "() => { const c = document.querySelector('#viewport .framer-viewport-overlay').getBoundingClientRect(); return Math.abs(c.width - window.__zoomFitW) < 2 && c.width < window.__zoomOutBase; }"
            },
            # Back at the fit floor, a third bone still lands under the pointer.
            %{
              name: "create a bone from image (1400,980) to (1500,980) at the fit",
              dragImage: %{
                from: [1400, 980],
                to: [1500, 980],
                imgW: 2000,
                imgH: 1400,
                settleMs: 300
              }
            },
            %{
              name: "third bone reaches the editor hierarchy",
              waitForFunction:
                "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 3"
            },
            bone_head_error(2, 1400, 980)
          ]
    }

    assert run_scenario(spec, root) == :ok

    # Pixel proof that the rendered image scale really changed: the still fills
    # more of the viewport when zoomed in than at the contain-fit.
    assert %{width: wf, height: hf} = assert_png!(subj_fit)
    assert %{width: wz, height: hz} = assert_png!(subj_zoomed)

    fit_count = subject_pixels(subj_fit, wf, hf)
    zoomed_count = subject_pixels(subj_zoomed, wz, hz)
    assert fit_count >= @subject_min
    assert zoomed_count > fit_count
  end

  # The shared zoom-proof setup: open the editor and create a still much larger
  # than the viewport element, then wait for its preview. The fit baseline is
  # recorded by the scenario itself, after the first bone settles the element.
  defp zoom_steps(name) do
    [
      %{name: "open the editor shell", open: "/editor"},
      %{name: "shell renders", waitForSelector: "#editor-shell"},
      %{
        name: "create a still much larger than the viewport",
        fetch: %{
          url: "/api/rigs",
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: %{
            "name" => name,
            "filename" => "subject.png",
            "source_base64" => Base.encode64(Fixtures.png_with_subject(2000, 1400, @subject))
          }
        },
        saveAs: "create"
      },
      %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
      %{name: "viewport renders", waitForSelector: "#viewport"},
      %{
        name: "source image drawn",
        waitForFunction:
          "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
      },
      %{name: "let the preview settle", sleep: 1_000}
    ]
  end

  # The captain's ask: "add some small dots around each edge of the vertice; so
  # that We can link them together" - a drag from one bone's link dot onto
  # another bone parents the first onto the second, instead of selecting a bone
  # and picking its parent from the dropdown. This proof drags the real violet
  # link dot (the runner computes its on-screen centre from the bone's image
  # coordinates the same way the hook draws it), asserts the parent is set on
  # the persisted rig, and asserts the dotted parent link renders on the overlay
  # canvas between the two bones.
  test "bones tool: a link handle drag parents one bone onto another", %{root: root} do
    shots = Path.join(root, "link_parent")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        two_bone_steps("browser-link-parent", [150, 300], [250, 300], [350, 300], [450, 300]) ++
          [
            %{
              name: "drag b1's link dot onto b0's body",
              dragLink: %{
                head: [350, 300],
                tail: [450, 300],
                to: [200, 300],
                imgW: 600,
                settleMs: 500
              }
            },
            %{
              name: "b1 is now parented to b0 on the persisted rig",
              evaluate:
                "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return rig.bones[1].parent; }",
              expect: %{eq: "b0"}
            },
            %{
              name: "the dotted parent link renders between b0's tail and b1's head",
              evaluate: link_line_band(258, 342, 300, 4, 15)
            },
            %{
              name: "zero page errors",
              evaluate: "() => window.__framerErrors.length",
              expect: %{eq: 0}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok
  end

  # The companion refusal: once b1 is parented to b0, dragging b0's link dot
  # onto b1 would cycle the hierarchy. The drag must be refused exactly as the
  # parent dropdown refuses it - an inline error, and the persisted document
  # unchanged.
  test "bones tool: a link drag that would cycle is refused", %{root: root} do
    shots = Path.join(root, "link_cycle")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        two_bone_steps("browser-link-cycle", [150, 300], [250, 300], [350, 300], [450, 300]) ++
          [
            %{
              name: "first parent b1 onto b0",
              dragLink: %{
                head: [350, 300],
                tail: [450, 300],
                to: [200, 300],
                imgW: 600,
                settleMs: 500
              }
            },
            %{
              name: "now drag b0's link dot onto b1's body (would cycle)",
              dragLink: %{
                head: [150, 300],
                tail: [250, 300],
                to: [400, 300],
                imgW: 600,
                settleMs: 500
              }
            },
            %{
              name: "the cycle is refused with an inline error",
              waitForSelector: "#editor-error"
            },
            %{
              name: "the error names the cycle",
              evaluate:
                "() => { const e = document.querySelector('#editor-error'); return !!e && e.textContent.includes('cycle'); }",
              expect: %{eq: true}
            },
            %{
              name: "the persisted hierarchy is unchanged",
              evaluate:
                "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return (rig.bones[0].parent || 'none') + '|' + (rig.bones[1].parent || 'none'); }",
              expect: %{eq: "none|b0"}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok
  end

  # The chain case for the nearest-affordance-wins invariant: b1's head sits on
  # b0's tail, so b1's link dot is drawn directly over b0's barrel. A grab
  # there must move/select b0 (the nearer bone body) instead of starting a
  # link, and a mis-grab released over a third bone must leave b1's persisted
  # parent unchanged - the silent re-parent an absolute-priority link hit
  # caused.
  test "bones tool: a grab on a link dot over a bone body moves that bone", %{root: root} do
    shots = Path.join(root, "link_chain")
    File.mkdir_p!(shots)

    spec = %{
      baseUrl: @base_url,
      viewport: %{width: 1280, height: 900},
      failureScreenshot: Path.join(shots, "failure.png"),
      steps:
        two_bone_steps("browser-link-chain", [150, 300], [250, 300], [350, 300], [450, 300]) ++
          [
            %{
              name: "parent b1 onto b0 with its link dot (chain setup)",
              dragLink: %{
                head: [350, 300],
                tail: [450, 300],
                to: [200, 300],
                imgW: 600,
                settleMs: 500
              }
            },
            %{
              name: "b1 is parented to b0 before the chain forms",
              evaluate:
                "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return rig.bones[1].parent; }",
              expect: %{eq: "b0"}
            },
            %{
              name: "slide b1's head onto b0's tail so its link dot lands on b0's barrel",
              dragImage: %{from: [350, 300], to: [250, 300], imgW: 600, imgH: 600, settleMs: 500}
            },
            %{
              name: "draw b3 as the mis-grab drop target",
              dragImage: %{from: [150, 450], to: [250, 450], imgW: 600, imgH: 600, settleMs: 300}
            },
            %{
              name: "b3 reaches the editor hierarchy",
              waitForFunction:
                "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 3"
            },
            %{
              name: "grab b1's link dot (over b0's barrel) and release it over b3",
              dragLink: %{
                head: [250, 300],
                tail: [450, 300],
                to: [200, 450],
                imgW: 600,
                settleMs: 500
              }
            },
            %{
              name: "the grab selected b0, the nearer bone body",
              waitForFunction:
                "() => document.querySelector('#viewport').dataset.selected === 'b0'"
            },
            %{
              name: "the mis-grab left b1's persisted parent unchanged",
              evaluate:
                "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return rig.bones[1].parent; }",
              expect: %{eq: "b0"}
            },
            %{
              name: "b0's body moved with the mis-grab instead of a link starting",
              evaluate:
                "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; return Math.abs(rig.bones[0].rest.tail[1] - 450); }",
              expect: %{lt: 2}
            },
            %{
              name: "zero page errors",
              evaluate: "() => window.__framerErrors.length",
              expect: %{eq: 0}
            }
          ]
    }

    assert run_scenario(spec, root) == :ok
  end

  # Counts the slate parent-link pixels the overlay canvas paints inside an
  # image-coordinate band. The link line is the only slate element in the
  # overlay (bones are sky, joints ivory, handles amber, link dots violet, mesh
  # white, labels near-white), so any matching pixel in the band is the dotted
  # link. The band excludes both joints' own pixels, whose antialiased edges
  # blend to a similar slate where the bone stroke meets the joint disc.
  defp link_line_band(x0, x1, y, half_height, min_hits) do
    body = """
    async () => {
      const vp = document.querySelector('#viewport');
      const overlay = vp.querySelector('.framer-viewport-overlay');
      const ctx = overlay.getContext('2d');
      const id = vp.dataset.sourceUrl.split('/')[3];
      const j = await (await fetch('/api/rigs/' + id)).json();
      const rig = j.rig || j;
      const dpr = window.devicePixelRatio || 1;
      const scale = overlay.width / dpr / rig.canvas.width;
      const left = Math.floor(#{x0} * scale * dpr);
      const right = Math.ceil(#{x1} * scale * dpr);
      const top = Math.floor((#{y} - #{half_height}) * scale * dpr);
      const bottom = Math.ceil((#{y} + #{half_height}) * scale * dpr);
      const data = ctx.getImageData(left, top, right - left + 1, bottom - top + 1).data;
      let hits = 0;
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3];
        if (a >= 60 && r >= 90 && r <= 210 && g >= r && b >= g && b - g <= 60) hits++;
      }
      return hits;
    }
    """

    %{name: "count link pixels in the band", body: body, expect: %{gte: min_hits}}
  end

  # --- scenario runner -----------------------------------------------------

  # The steps a link-drag proof shares: create a 600x600 rig, open it, wait for
  # the preview, then draw two horizontal bones (b0 first, then b1) at the given
  # image coordinates. Each drag starts far from the other bone's tip, so the
  # create gesture never auto-parents and the two bones begin unrelated.
  defp two_bone_steps(name, b0_head, b0_tail, b1_head, b1_tail) do
    [
      %{name: "open the editor shell", open: "/editor"},
      %{name: "shell renders", waitForSelector: "#editor-shell"},
      %{
        name: "create a rig over the API",
        fetch: %{
          url: "/api/rigs",
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: %{
            "name" => name,
            "filename" => "subject.png",
            "source_base64" => Base.encode64(Fixtures.png_with_subject(600, 600, @subject))
          }
        },
        saveAs: "create"
      },
      %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
      %{name: "viewport renders", waitForSelector: "#viewport"},
      %{
        name: "source image drawn",
        waitForFunction:
          "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
      },
      %{name: "let the preview settle", sleep: 1_000},
      %{
        name: "draw b0",
        dragImage: %{from: b0_head, to: b0_tail, imgW: 600, imgH: 600, settleMs: 300}
      },
      %{
        name: "b0 reaches the editor hierarchy",
        waitForSelector: "button[phx-click=\"select_bone\"]"
      },
      %{
        name: "draw b1",
        dragImage: %{from: b1_head, to: b1_tail, imgW: 600, imgH: 600, settleMs: 300}
      },
      %{
        name: "b1 reaches the editor hierarchy",
        waitForFunction:
          "() => document.querySelectorAll('button[phx-click=\"select_bone\"]').length >= 2"
      },
      %{name: "let both bones settle", sleep: 300}
    ]
  end

  # The steps every slice-4 scenario shares: create a rig with the red-subject
  # still, open it, wait for the preview, and drag one bone into the viewport
  # (bone_created selects it, so its amber overlay stroke is countable).
  defp rig_with_bone_steps(name) do
    [
      %{name: "open the editor shell", open: "/editor"},
      %{name: "shell renders", waitForSelector: "#editor-shell"},
      %{
        name: "create a rig over the API",
        fetch: %{
          url: "/api/rigs",
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: %{
            "name" => name,
            "filename" => "subject.png",
            "source_base64" => Base.encode64(Fixtures.png_with_subject(64, 64, @subject))
          }
        },
        saveAs: "create"
      },
      %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
      %{name: "viewport renders", waitForSelector: "#viewport"},
      %{
        name: "source image drawn",
        waitForFunction:
          "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
      },
      %{name: "let the preview settle", sleep: 1_000},
      %{
        name: "draw one bone (drag across the viewport)",
        drag: %{
          selector: "#viewport",
          from: %{fx: 0.5, fy: 0.35},
          to: %{fx: 0.5, fy: 0.65},
          steps: 8,
          settleMs: 300
        }
      },
      %{
        name: "bone reaches the editor hierarchy",
        waitForSelector: "button[phx-click=\"select_bone\"]"
      },
      %{name: "let the bone overlay draw", sleep: 500}
    ]
  end

  # Asserts a bone's head landed at the clicked image point. Reads the rig back
  # over the API (the store the editor persists through) and returns the
  # euclidean distance to the expected point; the runner compares it against a
  # 2px tolerance, tight enough to catch the stale-view offset the captain
  # reported but generous enough to ignore sub-pixel mouse rounding.
  defp bone_head_error(bone_index, x, y) do
    %{
      name: "bone #{bone_index} head lands at (#{x}, #{y})",
      evaluate:
        "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; const head = rig.bones[#{bone_index}].rest.head; return Math.hypot(head[0] - #{x}, head[1] - #{y}); }",
      expect: %{lt: 2}
    }
  end

  # Asserts a bone's head or tail ("head" | "tail") landed at the expected image
  # point. Reads the rig back over the API and returns the euclidean distance;
  # the runner compares it against a 2px tolerance.
  defp bone_joint_error(bone_index, which, x, y) do
    %{
      name: "bone #{bone_index} #{which} lands at (#{x}, #{y})",
      evaluate:
        "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; const joint = rig.bones[#{bone_index}].rest.#{which}; return Math.hypot(joint[0] - #{x}, joint[1] - #{y}); }",
      expect: %{lt: 2}
    }
  end

  # The shared shape of the live-drag proofs: a 200x200 still whose red subject
  # block is centred on image (100,100), one horizontal bone through the centre
  # row (head (60,100), tail (140,100)), a pointer press on the head joint or
  # the bone body, and a held move to the still's centre. The steps hold the
  # pointer down across the screenshot, so the captured overlay is the drag in
  # progress; `opts.landed_head` / `opts.landed_tail` are the image points the
  # release must commit the bone to (what the drawn overlay showed).
  defp live_drag_steps(opts) do
    %{
      name: name,
      shot: shot,
      press_at: press_at,
      press_label: press_label,
      move_to: move_to,
      landed_head: landed_head,
      landed_tail: landed_tail
    } = opts

    [
      %{name: "open the editor shell", open: "/editor"},
      %{name: "shell renders", waitForSelector: "#editor-shell"},
      %{
        name: "create a rig whose subject block is centred on image (100,100)",
        fetch: %{
          url: "/api/rigs",
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: %{
            "name" => name,
            "filename" => "subject.png",
            "source_base64" => Base.encode64(Fixtures.png_with_subject(200, 200, @subject))
          }
        },
        saveAs: "create"
      },
      %{name: "open the rig", open: "/editor?rig={{create.rig.id}}"},
      %{name: "viewport renders", waitForSelector: "#viewport"},
      %{
        name: "source image drawn",
        waitForFunction:
          "() => { const s = document.querySelector('#viewport .framer-viewport-status'); return !!s && s.style.display === 'none'; }"
      },
      %{name: "let the preview settle", sleep: 1_000},
      %{
        name: "create a bone from image (60,100) to (140,100)",
        dragImage: %{from: [60, 100], to: [140, 100], imgW: 200, imgH: 200, settleMs: 300}
      },
      %{
        name: "bone reaches the editor hierarchy",
        waitForSelector: "button[phx-click=\"select_bone\"]"
      },
      %{name: "let the bone overlay draw", sleep: 500},
      %{
        name:
          "press the #{press_label} at image (#{press_at |> Enum.at(0)},#{press_at |> Enum.at(1)})",
        pointerDown: %{at: press_at, imgW: 200, imgH: 200}
      },
      %{
        name:
          "move the pointer to image (#{move_to |> Enum.at(0)},#{move_to |> Enum.at(1)}), the still's centre",
        pointerMove: %{at: move_to, imgW: 200, imgH: 200}
      },
      # Mid-drag the edit is not committed yet: the stored rest is still the
      # pre-drag one, so the screenshot that follows observes client-side
      # rendering rather than the document the server would push on release.
      %{
        name: "the server still holds the pre-drag rest while the pointer is down",
        evaluate:
          "async () => { const vp = document.querySelector('#viewport'); const id = vp.dataset.sourceUrl.split('/')[3]; const j = await (await fetch('/api/rigs/' + id)).json(); const rig = j.rig || j; const head = rig.bones[0].rest.head; return Math.hypot(head[0] - 60, head[1] - 100); }",
        expect: %{lt: 2}
      },
      %{
        name: "screenshot the in-progress drag",
        screenshot: %{path: shot, selector: "#viewport"}
      },
      %{
        name: "the pointer-up draw holds the dropped joint (in-page release, no rest-pose frame)",
        evaluate:
          "() => { window.dispatchEvent(new PointerEvent('pointerup', { bubbles: true })); const overlay = document.querySelector('#viewport canvas.framer-viewport-overlay'); const w = overlay.width, h = overlay.height; const rect = overlay.getBoundingClientRect(); const dpr = window.devicePixelRatio || 1; const tx = #{landed_head |> Enum.at(0)} * (rect.width / 200) * dpr, ty = #{landed_head |> Enum.at(1)} * (rect.width / 200) * dpr; const pixels = overlay.getContext('2d').getImageData(0, 0, w, h).data; let jx = 0, jy = 0, jn = 0; for (let y = 0; y < h; y++) { for (let x = 0; x < w; x++) { const i = (y * w + x) * 4; if (pixels[i] >= 200 && pixels[i + 1] >= 175 && pixels[i + 2] <= 120 && pixels[i + 3] >= 200 && Math.hypot(x - tx, y - ty) <= #{@alignment_window}) { jx += x; jy += y; jn++; } } } if (jn < #{@joint_min}) return 999999; return Math.hypot(jx / jn - tx, jy / jn - ty); }",
        expect: %{lt: @alignment_tolerance}
      },
      %{name: "finish the release and let the commit settle", pointerUp: %{settleMs: 300}},
      bone_joint_error(0, "head", landed_head |> Enum.at(0), landed_head |> Enum.at(1)),
      bone_joint_error(0, "tail", landed_tail |> Enum.at(0), landed_tail |> Enum.at(1))
    ]
  end

  defp run_scenario(spec, root) do
    spec_path = Path.join(root, "scenario_#{System.unique_integer([:positive])}.json")
    File.write!(spec_path, Jason.encode!(spec))

    node = System.find_executable("node") || flunk("node is missing")

    {output, status} =
      System.cmd(node, [@runner, spec_path], cd: @browser_dir, stderr_to_stdout: true)

    unless status == 0 do
      flunk("browser scenario failed (exit #{status}):\n#{output}")
    end

    :ok
  end

  # --- pixel assertions ----------------------------------------------------

  # Validates the screenshot is a decodable PNG (FramerWeb.ImageInfo.read, the
  # repo's own header reader) and returns its dimensions.
  defp assert_png!(path) do
    case ImageInfo.read(File.read!(path)) do
      {:ok, info} -> info
      {:error, reason} -> flunk("#{path} is not a readable image: #{inspect(reason)}")
    end
  end

  # Decodes the PNG screenshot to raw RGBA with ffmpeg (the same recipe
  # rig_e2e_test.exs uses for its frames), so pixel counting needs no PNG
  # library in either language.
  defp raw_rgba(path) do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required to decode screenshots")

    {raw, status} =
      System.cmd(
        ffmpeg,
        ["-v", "error", "-i", path, "-pix_fmt", "rgba", "-f", "rawvideo", "-"],
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("ffmpeg could not decode #{path}: #{raw}")
    raw
  end

  defp count_pixels(path, width, height, predicate) do
    raw = raw_rgba(path)
    row_size = width * 4

    for y <- 0..(height - 1), reduce: 0 do
      acc ->
        row = binary_part(raw, y * row_size, row_size)

        for x <- 0..(width - 1), reduce: acc do
          inner_acc ->
            <<r, g, b, a>> = binary_part(row, x * 4, 4)
            if predicate.(r, g, b, a), do: inner_acc + 1, else: inner_acc
        end
    end
  end

  # The red subject block of Fixtures.png_with_subject (saturated red,
  # opaque); bone and joint overlays are amber/slate and never match.
  defp subject_pixels(path, width, height) do
    count_pixels(path, width, height, &subject_pixel?/4)
  end

  defp subject_pixel?(r, g, b, a) do
    r >= 200 and g <= 60 and b <= 60 and a >= 200
  end

  # The joint disc of a selected bone: #fbbf24, lighter than the amber stroke
  # (#f59e0b, g 158) and the translucent influence ring, neither of which
  # matches, so a centroid built from these pixels is centred on the joint.
  defp joint_pixel?(r, g, b, a) do
    r >= 200 and g >= 175 and b <= 120 and a >= 200
  end

  # One pass over the screenshot for the overlay-alignment proofs: the bounding
  # box of the saturated red subject block (the still's on-screen rectangle) and
  # the centroid of the joint-disc pixels inside `window` device pixels of its
  # centre. The image point comes back `nil` when no subject block is on screen.
  defp alignment_scan(path, width, height, window) do
    raw = raw_rgba(path)
    row_size = width * 4

    {box, joints} =
      for y <- 0..(height - 1), reduce: {nil, []} do
        {box, joints} ->
          row = binary_part(raw, y * row_size, row_size)

          for x <- 0..(width - 1), reduce: {box, joints} do
            {box, joints} ->
              <<r, g, b, a>> = binary_part(row, x * 4, 4)

              cond do
                subject_pixel?(r, g, b, a) -> {grow_box(box, x, y), joints}
                joint_pixel?(r, g, b, a) -> {box, [{x, y} | joints]}
                true -> {box, joints}
              end
          end
      end

    {image_x, image_y} =
      case box_centre(box) do
        nil -> {nil, nil}
        centre -> centre
      end

    near =
      if image_x do
        for {x, y} <- joints,
            (x - image_x) ** 2 + (y - image_y) ** 2 <= window * window,
            do: {x, y}
      else
        []
      end

    {image_x, image_y, length(near), centroid_x(near), centroid_y(near)}
  end

  defp grow_box(nil, x, y), do: {x, y, x, y}

  defp grow_box({x0, y0, x1, y1}, x, y) do
    {min(x0, x), min(y0, y), max(x1, x), max(y1, y)}
  end

  defp box_centre(nil), do: nil
  defp box_centre({x0, y0, x1, y1}), do: {(x0 + x1) / 2, (y0 + y1) / 2}

  defp centroid_x([]), do: 0.0

  defp centroid_x(pixels),
    do: pixels |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Kernel./(length(pixels))

  defp centroid_y([]), do: 0.0

  defp centroid_y(pixels),
    do: pixels |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Kernel./(length(pixels))

  # Bone overlay pixels: the selected bone stroke (#f59e0b) and joint
  # (#fbbf24) the LbsPreview hook paints on its overlay canvas. The subject
  # red never matches (g == 0); the slate/white labels never match either.
  defp bone_pixels(path, width, height) do
    count_pixels(path, width, height, fn r, g, b, a ->
      r >= 200 and g >= 100 and b <= 120 and a >= 200
    end)
  end

  # --- endpoint ready poll ------------------------------------------------

  defp wait_until_serving!(attempts \\ 200) do
    case Req.get(@base_url <> "/api/status") do
      {:ok, %{status: 200}} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(100)
        wait_until_serving!(attempts - 1)

      _ ->
        flunk("the test endpoint never came up on #{@base_url}")
    end
  end
end
