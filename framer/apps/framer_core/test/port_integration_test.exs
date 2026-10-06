defmodule FramerCore.PortIntegrationTest do
  @moduledoc """
  End-to-end tests that actually execute the Port integration: a real small
  clip is generated with FFmpeg, split into chunks by the orchestrator, keyed
  by the Python/OpenCV worker and merged back to a final file.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias FramerCore.Orchestrator
  alias FramerCore.PortWorker

  @clip_frames 15
  @width 160
  @height 120

  setup_all do
    tmp = Path.join(System.tmp_dir!(), "framer_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    ffmpeg = System.find_executable("ffmpeg")

    if ffmpeg do
      clip = Path.join(tmp, "clip.mp4")
      generate_clip!(ffmpeg, clip)
      {:ok, tmp: tmp, clip: clip}
    else
      {:ok, tmp: tmp, clip: nil}
    end
  end

  setup %{clip: clip} do
    if clip == nil do
      flunk("ffmpeg is required to run the Port integration test")
    else
      case PortWorker.run_once(%{"op" => "info", "input" => clip}) do
        {:ok, _info} -> :ok
        {:error, reason} -> flunk("Python Port worker is not usable: #{inspect(reason)}")
      end
    end
  end

  test "remove-bg actually keys the background through the Port contract", %{tmp: tmp, clip: clip} do
    output = Path.join(tmp, "remove_bg.webm")

    options = %{
      "color" => "0,255,0",
      "tolerance" => 40,
      "edges" => 3,
      "method" => "color"
    }

    assert {:ok, job_id} =
             Orchestrator.submit_job(clip, output,
               operation: "remove-bg",
               options: options,
               total_frames: @clip_frames,
               fps: @clip_frames * 1.0
             )

    state = await_job(job_id)

    assert state.job.status == :completed
    assert state.failed_chunks == []
    assert length(state.completed_chunks) >= 1

    # The CLI performs the merge after the job completes; the integration test
    # does the same so the whole chunked pipeline is exercised end to end.
    assert {:ok, %{"output" => ^output}} =
             FramerCore.Operations.merge_job(state.job, state.completed_chunks)

    assert File.exists?(output)

    # The transparent corners prove the background was keyed, and the opaque
    # centre proves the subject survived.
    assert {:ok, alpha} = decode_alpha(output)

    assert alpha_corner(alpha) == 0
    assert alpha_center(alpha) == 255
  end

  test "a permanently failing chunk fails the job instead of counting as success", %{clip: clip} do
    output = Path.join(Path.dirname(clip), "should_not_exist.webm")

    assert {:ok, job_id} =
             Orchestrator.submit_job(clip, output,
               operation: "this-operation-does-not-exist",
               options: %{},
               total_frames: @clip_frames,
               fps: @clip_frames * 1.0
             )

    state = await_job(job_id)

    assert state.job.status == :failed
    assert state.completed_chunks == []
    assert length(state.failed_chunks) >= 1
    # The orchestrator must not have produced a partial final file.
    refute File.exists?(output)
  end

  test "worker count is configurable at runtime" do
    original = length(FramerCore.PlayerPool.players())

    on_exit(fn -> FramerCore.Supervisor.set_worker_count(original) end)

    assert :ok = FramerCore.Supervisor.set_worker_count(3)
    assert length(FramerCore.PlayerPool.players()) == 3

    assert :ok = FramerCore.Supervisor.set_worker_count(2)
    assert length(FramerCore.PlayerPool.players()) == 2
  end

  # --- helpers ---

  defp generate_clip!(ffmpeg, path) do
    filter = "drawbox=x=50:y=40:w=60:h=40:color=red@1:t=fill"

    {output, status} =
      System.cmd(
        ffmpeg,
        [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "color=c=0x00FF00:s=#{@width}x#{@height}:d=1:r=#{@clip_frames}",
          "-vf",
          filter,
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          path
        ],
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("could not generate test clip: #{output}")
    end

    :ok
  end

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

  defp decode_alpha(path) do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg missing")
    frame_size = @width * @height * 4

    # Force the libvpx decoder: FFmpeg's native VP9 decoder drops the alpha
    # plane, so a naive decode would report alpha on every pixel.
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

  defp alpha_corner(frame), do: :binary.at(frame, 3)

  defp alpha_center(frame) do
    index = (div(@height, 2) * @width + div(@width, 2)) * 4 + 3
    :binary.at(frame, index)
  end
end
