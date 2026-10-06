defmodule FramerCore.DeformIntegrationTest do
  @moduledoc """
  End-to-end test for the `deform` engine operation.

  A still RGBA image and a rig JSON document are generated on disk, then the
  real pipeline runs: `Orchestrator` chunks the frame range, the Python Port
  worker loops the still over each chunk and puppet-warps it, and
  `Operations.merge_job` concatenates the chunks.  The merged video is decoded
  frame by frame (with `libvpx-vp9`, because FFmpeg's native VP9 decoder drops
  the alpha plane) and the deformation is asserted on pixels.

  The BEAM never sees pixels: only the still path, the rig path, the range and
  the options cross the Port.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :requires_cv2
  @moduletag timeout: 300_000

  alias FramerCore.Orchestrator
  alias FramerCore.PortWorker

  @width 160
  @height 120
  @frames 16
  @fps 8
  @shift 40

  setup_all do
    tmp = Path.join(System.tmp_dir!(), "framer_deform_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    still = Path.join(tmp, "still.png")
    rig = Path.join(tmp, "rig.json")

    generate_still!(still)
    File.write!(rig, Jason.encode!(rig_document()))
    {:ok, tmp: tmp, still: still, rig: rig}
  end

  setup %{still: still} do
    case PortWorker.run_once(%{"op" => "info", "input" => still}) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("Python Port worker is not usable: #{inspect(reason)}")
    end
  end

  test "deform animates a still through the orchestrator and merge", %{
    tmp: tmp,
    still: still,
    rig: rig
  } do
    output = Path.join(tmp, "deform.webm")

    assert {:ok, job_id} =
             Orchestrator.submit_job(still, output,
               operation: "deform",
               options: %{"rig" => rig, "iterations" => 6, "still" => true},
               total_frames: @frames,
               fps: @fps * 1.0
             )

    state = await_job(job_id)

    assert state.job.status == :completed
    assert state.failed_chunks == []
    assert length(state.completed_chunks) >= 1

    assert {:ok, %{"output" => ^output}} =
             FramerCore.Operations.merge_job(state.job, state.completed_chunks)

    assert File.exists?(output)

    # Bind pose: the opaque subject sits at x = 50..109, transparent elsewhere.
    assert {:ok, first} = decode_frame(output, 0)
    assert alpha_at(first, 80, 60) == 255
    assert alpha_at(first, 8, 8) == 0

    # Final pose: a pure +40px translation moves the subject to x = 90..149.
    assert {:ok, last} = decode_frame(output, @frames - 1)
    assert alpha_at(last, 80, 60) == 0
    assert alpha_at(last, 120, 60) == 255

    # The moved subject keeps its colour (B, G, R).
    {blue, green, red} = color_at(last, 120, 60)
    assert blue < 60 and green < 60 and red > 200
  end

  # --- fixtures ---

  defp rig_document do
    %{
      "schema" => "framer.rig",
      "version" => 1,
      "canvas" => %{"width" => @width, "height" => @height},
      "source" => %{"kind" => "image", "path" => "still.png", "frame" => 0},
      "duration" => %{"fps" => @fps, "frames" => @frames},
      "bones" => [
        %{
          "id" => "b0",
          "name" => "root",
          "parent" => nil,
          "rest" => %{"head" => [80, 60], "tail" => [80, 20]},
          "radius" => 400,
          "falloff" => "smooth"
        }
      ],
      "bind" => %{"power" => 2.0, "radius_scale" => 1.0},
      "keyframes" => [
        %{"frame" => 0, "pose" => %{"b0" => %{"rot" => 0.0, "tx" => 0, "ty" => 0}}},
        %{"frame" => @frames - 1, "pose" => %{"b0" => %{"rot" => 0.0, "tx" => @shift, "ty" => 0}}}
      ]
    }
  end

  defp generate_still!(path) do
    python = PortWorker.python_executable()

    script = """
    import sys
    import cv2
    import numpy as np
    width, height = #{@width}, #{@height}
    image = np.zeros((height, width, 4), dtype=np.uint8)
    image[40:80, 50:110] = [0, 0, 255, 255]
    assert cv2.imwrite(sys.argv[1], image), "imwrite failed"
    """

    case System.cmd(python, ["-c", script, path], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> flunk("could not generate still (status #{status}): #{out}")
    end
  end

  # --- helpers ---

  defp await_job(job_id, attempts \\ 120) do
    state = Orchestrator.get_status()

    cond do
      state.job && state.job.id == job_id && state.job.status in [:completed, :failed] ->
        state

      attempts <= 0 ->
        flunk("job #{job_id} did not finish in time: #{inspect(state.job)}")

      true ->
        Process.sleep(250)
        await_job(job_id, attempts - 1)
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

  defp color_at(frame, x, y) do
    base = (y * @width + x) * 4
    {:binary.at(frame, base), :binary.at(frame, base + 1), :binary.at(frame, base + 2)}
  end
end
