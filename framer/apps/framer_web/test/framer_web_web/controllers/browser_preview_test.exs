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

  # --- scenario runner -----------------------------------------------------

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
