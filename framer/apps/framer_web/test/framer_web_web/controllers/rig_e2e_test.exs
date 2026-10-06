defmodule FramerWebWeb.RigE2ETest do
  @moduledoc """
  End-to-end editor path through the JSON surface.

  This mirrors the engine's `port_integration_test.exs` template: a real still
  is uploaded, a real rig is bound, then the editor's own endpoints render a
  full-quality frame and export a chunked `deform` job. The merged video is
  decoded (with `libvpx-vp9`, because FFmpeg's native VP9 decoder drops alpha)
  and the deformation is asserted on pixels.

  Everything the BEAM sends the engine is a path, a frame range and JSON
  options - never pixels.
  """

  use FramerWebWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :requires_cv2
  @moduletag timeout: 300_000

  alias FramerCore.Orchestrator
  alias FramerWeb.Rig
  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  @width 64
  @height 64
  @frames 8
  @fps 8
  @shift 20

  setup_all do
    original = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_e2e_#{System.unique_integer([:positive])}")
    Application.put_env(:framer_web, :projects_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:framer_web, :projects_dir, original)
    end)

    :ok
  end

  test "upload -> bind -> render -> export -> download", %{conn: conn} do
    # 1. Upload a still through the API; the canvas is derived from the header.
    payload = %{
      "name" => "e2e",
      "filename" => "subject.png",
      "source_base64" => Base.encode64(Fixtures.png_with_subject(@width, @height))
    }

    %{"rig" => %{"id" => id}} = conn |> post(~p"/api/rigs", payload) |> json_response(201)

    # 2. Bind a bone and animate a pure translation.
    {:ok, rig} = RigStore.load(id)

    {rig, _bone_id} =
      Rig.add_bone(rig, [div(@width, 2), @height - 16], [div(@width, 2), 16], radius: @width)

    rig =
      rig
      |> Map.put("duration", %{"fps" => @fps, "frames" => @frames})
      |> Rig.record_keyframe(0, %{"b0" => %{"rot" => 0.0, "tx" => 0, "ty" => 0}})
      |> Rig.record_keyframe(@frames - 1, %{"b0" => %{"rot" => 0.0, "tx" => @shift, "ty" => 0}})
      |> Rig.auto_bind()

    assert {:ok, _} = RigStore.save(rig)

    # 3. Render one full-quality frame through the engine.
    bind_frame = conn |> post(~p"/api/rigs/#{id}/render", %{"frame" => 0}) |> response(200)

    posed_frame =
      conn |> post(~p"/api/rigs/#{id}/render", %{"frame" => @frames - 1}) |> response(200)

    assert <<0x89, "PNG", _::binary>> = bind_frame
    assert bind_frame != posed_frame
    assert {:ok, %{width: @width, height: @height}} = FramerWeb.ImageInfo.read(bind_frame)

    # 4. Export the whole animation as a chunked deform job.
    export = conn |> post(~p"/api/rigs/#{id}/export", %{"format" => "webm"}) |> json_response(202)
    job_id = export["job_id"]

    state = await_job(job_id)
    assert state.job.status == :completed
    assert state.failed_chunks == []

    # 5. The server-side watcher merges the chunks; download the result.
    output = await_result(conn, id)
    assert byte_size(output) > 0

    # 6. Decode the merged WebM and assert the subject actually moved.
    assert {:ok, first} = decode_frame(Path.join(RigStore.project_dir(id), "output.webm"), 0)
    assert alpha_at(first, 32, 32) == 255

    assert {:ok, last} =
             decode_frame(Path.join(RigStore.project_dir(id), "output.webm"), @frames - 1)

    assert alpha_at(last, 32, 32) == 0
    assert alpha_at(last, 52, 32) == 255
  end

  # --- helpers ---

  defp await_job(job_id, attempts \\ 200) do
    state = Orchestrator.get_status()

    cond do
      state.job && state.job.id == job_id && state.job.status in [:completed, :failed] ->
        state

      attempts <= 0 ->
        flunk("job #{job_id} did not finish in time: #{inspect(state.job)}")

      true ->
        Process.sleep(200)
        await_job(job_id, attempts - 1)
    end
  end

  defp await_result(conn, id, attempts \\ 100) do
    response = get(conn, ~p"/api/rigs/#{id}/result")

    cond do
      response.status == 200 ->
        response.resp_body

      attempts <= 0 ->
        flunk("result was never available (status #{response.status})")

      true ->
        Process.sleep(200)
        await_result(conn, id, attempts - 1)
    end
  end

  defp decode_frame(path, frame) do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg missing")
    frame_size = @width * @height * 4

    {raw, status} =
      System.cmd(
        ffmpeg,
        [
          "-v",
          "error",
          "-c:v",
          "libvpx-vp9",
          "-i",
          path,
          "-vf",
          "select=eq(n\\,#{frame})",
          "-frames:v",
          "1",
          "-pix_fmt",
          "bgra",
          "-f",
          "rawvideo",
          "-"
        ],
        stderr_to_stdout: false
      )

    if status != 0 or byte_size(raw) < frame_size do
      {:error, :decode_failed}
    else
      {:ok, binary_part(raw, 0, frame_size)}
    end
  end

  defp alpha_at(frame, x, y), do: :binary.at(frame, (y * @width + x) * 4 + 3)
end
