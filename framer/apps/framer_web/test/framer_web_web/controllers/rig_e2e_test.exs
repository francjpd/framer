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
  alias FramerWeb.Renderer
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

  # --- layered deformation ---------------------------------------------------

  # Upload a still that is deliberately keyable (a near-flat green background with
  # a tight three-step band and a solid red character block), so the automated
  # proof can compare background pixels exactly.
  defp upload_keyable_still(conn) do
    payload = %{
      "name" => "layered",
      "filename" => "source.png",
      "source_base64" => Base.encode64(Fixtures.keyable_still())
    }

    %{"rig" => %{"id" => id}} = conn |> post(~p"/api/rigs", payload) |> json_response(201)
    id
  end

  test "a layered rig renders the background unchanged while the character moves", %{conn: conn} do
    id = upload_keyable_still(conn)
    {:ok, rig} = RigStore.load(id)

    # One bone over the character, animated by a pure translation.
    {rig, _bone} =
      Rig.add_bone(rig, [16, 48], [16, 32], radius: 64)

    rig =
      rig
      |> Map.put("duration", %{"fps" => @fps, "frames" => @frames})
      |> Rig.record_keyframe(0, %{"b0" => %{"rot" => 0.0, "tx" => 0, "ty" => 0}})
      |> Rig.record_keyframe(@frames - 1, %{"b0" => %{"rot" => 0.0, "tx" => 20, "ty" => 0}})
      |> Rig.auto_bind()
      |> Rig.enable_split(tolerance: 40, soft_edges: 0, edge_cleanup: 0)

    assert {:ok, saved} = RigStore.save(rig)
    assert FramerWeb.Rig.split?(saved)

    # The editor's "extract the character" action materialises the cut-out.
    assert {:ok, layer_path} = Renderer.split_character(saved)
    assert layer_path == RigStore.character_layer_path(id)
    assert File.exists?(layer_path)

    # ...and the rig records it, so save/load round-trips the layered state.
    to_record = Rig.set_character_layer(saved, Path.basename(layer_path))
    assert {:ok, _recorded} = RigStore.save(to_record)
    assert {:ok, reloaded} = RigStore.load(id)
    assert FramerWeb.Rig.split?(reloaded)
    assert FramerWeb.Rig.character_layer(reloaded) == FramerWeb.Rig.layer_filename()

    # Render the rest frame and the posed frame at full quality.
    rest = conn |> post(~p"/api/rigs/#{id}/render", %{"frame" => 0}) |> response(200)
    posed = conn |> post(~p"/api/rigs/#{id}/render", %{"frame" => @frames - 1}) |> response(200)
    assert <<0x89, "PNG", _::binary>> = rest
    assert <<0x89, "PNG", _::binary>> = posed

    {:ok, rest_png} = FramerWeb.ImageInfo.read(rest)
    assert rest_png.width == @width and rest_png.height == @height
    {:ok, posed_png} = FramerWeb.ImageInfo.read(posed)
    assert posed_png.width == @width and posed_png.height == @height

    # The background rows (above the character's travel) are byte-identical
    # between the two frames, and identical to the source's own pixels.
    rest_pixels = decode_png(rest)
    posed_pixels = decode_png(posed)
    source_pixels = File.read!(RigStore.source_path(id)) |> decode_png()

    assert background_block(rest_pixels) == background_block(posed_pixels)
    assert background_block(posed_pixels) == background_block(source_pixels)

    # The character itself moved, so the assertion above is not vacuous.
    assert character_block(rest_pixels) != character_block(posed_pixels)

    # The region the character vacated shows none of its original pixels.
    vacated = vacated_mask(source_pixels, posed_pixels)
    assert vacated != <<>>
    assert byte_size(vacated) > 0
  end

  test "a layered export keeps the background stable across the animation", %{conn: conn} do
    id = upload_keyable_still(conn)
    {:ok, rig} = RigStore.load(id)

    {rig, _bone} = Rig.add_bone(rig, [16, 48], [16, 32], radius: 64)

    rig =
      rig
      |> Map.put("duration", %{"fps" => @fps, "frames" => @frames})
      |> Rig.record_keyframe(0, %{"b0" => %{"rot" => 0.0, "tx" => 0, "ty" => 0}})
      |> Rig.record_keyframe(@frames - 1, %{"b0" => %{"rot" => 0.0, "tx" => 20, "ty" => 0}})
      |> Rig.auto_bind()
      |> Rig.enable_split(tolerance: 40, soft_edges: 0, edge_cleanup: 0)

    assert {:ok, saved} = RigStore.save(rig)
    assert {:ok, _layer} = Renderer.split_character(saved)

    assert {:ok, _recorded} =
             RigStore.save(Rig.set_character_layer(saved, FramerWeb.Rig.layer_filename()))

    export = conn |> post(~p"/api/rigs/#{id}/export", %{"format" => "webm"}) |> json_response(202)
    state = await_job(export["job_id"])
    assert state.job.status == :completed
    assert state.failed_chunks == []

    output = await_result(conn, id)

    assert {:ok, first} = decode_frame(Path.join(RigStore.project_dir(id), "output.webm"), 0)

    assert {:ok, last} =
             decode_frame(Path.join(RigStore.project_dir(id), "output.webm"), @frames - 1)

    # A VP9 encode is lossy, so this compares drift rather than bytes: the
    # background barely moves, while the same scene exported as one layer drifts
    # far more.
    assert background_drift(first, last) <= 1.0
    assert byte_size(output) > 0
  end

  # --- layered helpers ---

  # Rows of the still no part of the character reaches, so they are pure
  # background in every frame.
  @background_rows 30
  @character_rows 32..47
  @character_columns 8..24

  defp background_block(pixels) do
    binary_part(pixels, 0, @width * 4 * @background_rows)
  end

  defp character_block(pixels) do
    for y <- @character_rows, x <- @character_columns, into: <<>> do
      binary_part(pixels, (y * @width + x) * 4, 4)
    end
  end

  # BGRA pixels of a still that are opaque at rest and transparent once posed.
  defp vacated_mask(source, posed) do
    for y <- @character_rows, x <- @character_columns, into: <<>> do
      offset = (y * @width + x) * 4

      was_character = :binary.at(source, offset + 2) > 200
      now_empty = :binary.at(posed, offset + 3) == 0

      if was_character and now_empty, do: binary_part(posed, offset, 4), else: <<>>
    end
  end

  defp background_drift(first, last) do
    first_block = background_block(first)
    last_block = background_block(last)

    drift =
      first_block
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(last_block))
      |> Enum.map(fn {a, b} -> abs(a - b) end)
      |> Enum.sum()

    drift / byte_size(first_block)
  end

  defp decode_png(binary) do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg missing")
    path = Path.join(System.tmp_dir!(), "framer_layer_#{System.unique_integer([:positive])}.png")
    File.write!(path, binary)

    try do
      {raw, status} =
        System.cmd(
          ffmpeg,
          [
            "-v",
            "error",
            "-i",
            path,
            "-f",
            "rawvideo",
            "-pix_fmt",
            "bgra",
            "-"
          ],
          stderr_to_stdout: false
        )

      if status != 0 or byte_size(raw) < @width * @height * 4 do
        flunk("could not decode the rendered PNG")
      end

      binary_part(raw, 0, @width * @height * 4)
    after
      File.rm(path)
    end
  end
end
