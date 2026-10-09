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

  # --- scenario runner -----------------------------------------------------

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
    count_pixels(path, width, height, fn r, g, b, a ->
      r >= 200 and g <= 60 and b <= 60 and a >= 200
    end)
  end

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
