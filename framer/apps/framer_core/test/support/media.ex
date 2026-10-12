defmodule FramerCore.TestMedia do
  @moduledoc """
  Shared test media helpers.

  Generating a green-screen clip with FFmpeg and decoding an alpha plane (with
  the `libvpx-vp9` decoder, because FFmpeg's native VP9 decoder drops alpha)
  is the same work for every end-to-end test, so it lives here instead of being
  copied between the Port integration and escript suites.
  """

  @clip_frames 15
  @width 160
  @height 120

  @doc "The geometry every generated test clip uses."
  def geometry, do: %{width: @width, height: @height, frames: @clip_frames}

  @doc "Write a small green-screen clip with a red subject into `dir`."
  @spec write_clip!(Path.t()) :: Path.t()
  def write_clip!(dir) do
    ffmpeg = System.find_executable("ffmpeg") || raise "ffmpeg is not on PATH"
    path = Path.join(dir, "clip.mp4")
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

    status == 0 || raise "could not generate test clip (status #{status}): #{output}"
    path
  end

  @doc "Write a still RGBA image with a red subject into `dir`."
  @spec write_still!(Path.t()) :: Path.t()
  def write_still!(dir) do
    path = Path.join(dir, "still.png")

    script = """
    import sys
    import cv2
    import numpy as np
    image = np.zeros((#{@height}, #{@width}, 4), dtype=np.uint8)
    image[40:80, 50:110] = [0, 0, 255, 255]
    assert cv2.imwrite(sys.argv[1], image), "imwrite failed"
    """

    python = FramerCore.PortWorker.python_executable()

    case System.cmd(python, ["-c", script, path], stderr_to_stdout: true) do
      {_out, 0} -> path
      {out, status} -> raise "could not generate still (status #{status}): #{out}"
    end
  end

  @doc "Decode the first frame of an alpha video as BGRA bytes."
  @spec decode_alpha(Path.t()) :: {:ok, binary()} | {:error, :decode_failed}
  def decode_alpha(path) do
    ffmpeg = System.find_executable("ffmpeg") || raise "ffmpeg is not on PATH"
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

  @doc "The alpha byte of the top-left corner of a decoded BGRA frame."
  def corner_alpha(frame), do: :binary.at(frame, 3)

  @doc "The alpha byte of the centre of a decoded BGRA frame."
  def center_alpha(frame) do
    index = (div(@height, 2) * @width + div(@width, 2)) * 4 + 3
    :binary.at(frame, index)
  end
end
