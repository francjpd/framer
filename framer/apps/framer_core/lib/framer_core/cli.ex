defmodule FramerCore.CLI do
  @moduledoc """
  Command-line interface for Framer.

  Usage:
      mix run -e "FramerCore.CLI.main([\"info\", \"input.mp4\"])"
      mix run -e "FramerCore.CLI.main([\"transcode\", \"input.mp4\", \"output.webm\"])"
      mix run -e "FramerCore.CLI.main([\"fps-boost\", \"input.mp4\", \"output.mp4\", \"--to\", \"60\"])"
      mix run -e "FramerCore.CLI.main([\"remove-bg\", \"input.mp4\", \"output.webm\", \"--color\", \"0,255,0\"])"
      mix run -e "FramerCore.CLI.main([\"loop\", \"input.mp4\", \"output.mp4\", \"--method\", \"pingpong\"])"
  """

  def main(args \\ []) do
    case args do
      ["info", path] ->
        info(path)

      ["transcode", input, output] ->
        transcode(input, output)

      ["process", input, output, start_frame, end_frame] ->
        {start, _} = Integer.parse(start_frame)
        {end_f, _} = Integer.parse(end_frame)
        process_chunk(input, output, start, end_f)

      ["apply-filter", input, output, filter] ->
        apply_filter(input, output, filter)

      ["fps-boost", input, output | opts] ->
        fps_boost(input, output, opts)

      ["remove-bg", input, output | opts] ->
        remove_bg(input, output, opts)

      ["loop", input, output | opts] ->
        loop_op(input, output, opts)

      _ ->
        help()
    end
  end

  # --- Existing commands ---

  defp info(path) do
    IO.puts("Getting info for: #{path}")

    result = info_json(path)

    case result do
      {:ok, %{width: w, height: h, fps: fps, total_frames: frames}} ->
        IO.puts("""
        Video Info:
          Resolution: #{w}x#{h}
          FPS: #{fps}
          Frames: #{frames}
        """)

      {:error, reason} ->
        IO.puts("Error: #{reason}")
    end
  end

  defp info_json(path) do
    case System.cmd("ffprobe", [
           "-v",
           "quiet",
           "-print_format",
           "json",
           "-show_format",
           "-show_streams",
           path
         ]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} ->
            video =
              Enum.find(
                data["streams"],
                fn s -> s["codec_type"] == "video" end
              )

            fps_str = get_in(video, ["r_frame_rate"]) || "0/1"
            [num, den] = String.split(fps_str, "/")
            fps = String.to_integer(num) / String.to_integer(den)

            {:ok,
             %{
               width: video["width"],
               height: video["height"],
               fps: fps,
               total_frames: video["nb_frames"] || 0
             }}

          _ ->
            {:error, "Failed to parse ffprobe output"}
        end

      {_, err} ->
        {:error, err}
    end
  end

  defp transcode(input, output) do
    IO.puts("Transcoding: #{input} -> #{output}")

    case System.cmd("ffmpeg", [
           "-y",
           "-i",
           input,
           "-c:v",
           "libx264",
           "-preset",
           "fast",
           "-crf",
           "23",
           "-c:a",
           "aac",
           output
         ]) do
      {_, 0} ->
        IO.puts("Success!")

      {_, err} ->
        IO.puts("Error: #{err}")
    end
  end

  defp process_chunk(input, output, start_frame, end_frame) do
    IO.puts("Processing chunk: #{input}")
    IO.puts("  Frames: #{start_frame} - #{end_frame}")
    IO.puts("  Output: #{output}")

    start_time = start_frame / 30.0
    duration = (end_frame - start_frame + 1) / 30.0

    case System.cmd("ffmpeg", [
           "-y",
           "-ss",
           "#{start_time}",
           "-i",
           input,
           "-t",
           "#{duration}",
           "-c:v",
           "libx264",
           "-preset",
           "fast",
           "-crf",
           "23",
           output
         ]) do
      {_, 0} ->
        IO.puts("Success!")

      {_, err} ->
        IO.puts("Error: #{err}")
    end
  end

  defp apply_filter(input, output, filter) do
    IO.puts("Applying filter: #{filter}")
    IO.puts("  Input: #{input}")
    IO.puts("  Output: #{output}")

    case System.cmd("ffmpeg", [
           "-y",
           "-i",
           input,
           "-vf",
           filter,
           "-c:a",
           "copy",
           output
         ]) do
      {_, 0} ->
        IO.puts("Success!")

      {_, err} ->
        IO.puts("Error: #{err}")
    end
  end

  # --- New operation commands ---

  defp fps_boost(input, output, opts) do
    target_fps = parse_opt(opts, "--to", "60") |> String.to_integer()
    
    IO.puts("🚀 Parallel FPS Boost: #{input} -> #{output} (target: #{target_fps}fps)")

    # Get total frames and FPS to split the job correctly
    case info_json(input) do
      {:ok, %{total_frames: total_frames, fps: fps}} ->
        
        fps = 
          case fps do
            v when is_binary(v) -> String.to_float(v)
            v when is_number(v) -> v * 1.0
            _ -> 30.0
          end
       
        total_frames = if is_binary(total_frames), do: String.to_integer(total_frames), else: total_frames
        
        # Submit job to Orchestrator
        {:ok, job_id} = FramerCore.Orchestrator.submit_job(input, output, total_frames: total_frames, chunk_size: 50, fps: fps)
        
        IO.puts("📝 Job #{job_id} submitted with #{total_frames} frames @ #{fps}fps.")
        
        # Wait for completion (simple polling for CLI)
        wait_for_job(job_id)

      {:error, reason} ->
        IO.puts("Error getting video info: #{reason}")
    end
  end

  defp wait_for_job(job_id) do
    state = FramerCore.Orchestrator.get_status()
    
    if state.job && state.job.id == job_id && state.job.status == :completed do
      IO.puts("🎉 Job completed successfully!")
      # In a real impl, we'd merge chunks here
      merge_chunks(state.job)
    else
      Process.sleep(1000)
      wait_for_job(job_id)
    end
  end

  defp merge_chunks(job) do
    state = FramerCore.Orchestrator.get_status()
    chunks = state.completed_chunks
    
    IO.puts("🔗 Merging #{length(chunks)} chunks into final output: #{job.output_path}")
    
    # Create temp concat file
    concat_file_path = "/tmp/framer_concat_#{job.id}.txt"
    content = chunks 
              |> Enum.sort_by(&(&1.start_frame))
              |> Enum.map(fn chunk -> "file '#{chunk.output_path}'" end)
              |> Enum.join("\n")
    
    File.write!(concat_file_path, content)
    
    # Use ffmpeg to merge
    args = ["-y", "-f", "concat", "-safe", "0", "-i", concat_file_path, "-c", "copy", job.output_path]
    
    case System.cmd("ffmpeg", args) do
      {_, 0} ->
        IO.puts("✓ Success: #{job.output_path}")
        # Clean up chunks
        Enum.each(chunks, fn c -> File.rm(c.output_path) end)
        File.rm(concat_file_path)
      {err, _} ->
        IO.puts("❌ Merging failed: #{err}")
    end
  end

  defp handle_nif_result(json) do
    result = Jason.decode!(json)

    if result["success"],
      do: IO.puts("Success: #{result["output_path"]}"),
      else: IO.puts("Error: #{result["error"]}")
  end

  defp remove_bg(input, output, opts) do
    color_opt = parse_opt_or_nil(opts, "--color")

    color =
      if is_nil(color_opt) or color_opt == "auto" do
        case detect_bg_color(input) do
          {:ok, detected} ->
            detected

          _ ->
            "0,255,0"
        end
      else
        color_opt
      end

    tolerance = parse_opt(opts, "--tolerance", "20") |> String.to_integer()
    edges = parse_opt(opts, "--edges", "5") |> String.to_integer()
    method = parse_opt(opts, "--method", "colorkey")
    auto_ranges = parse_opt(opts, "--auto-ranges", "true") |> parse_bool()
    num_ranges = parse_opt(opts, "--num-ranges", "5") |> String.to_integer()
    edge_cleanup = parse_opt(opts, "--edge-cleanup", "3") |> String.to_integer()
    refine = parse_opt(opts, "--refine", "false") |> parse_bool()
    refine_tolerance = parse_opt(opts, "--refine-tolerance", "45") |> String.to_integer()
    refine_block_size = parse_opt(opts, "--refine-block-size", "32") |> String.to_integer()

    IO.puts(
      "Remove BG: #{input} -> #{output} (color: #{color}, tol: #{tolerance}, method: #{method})"
    )

    case FramerCore.Rust.remove_bg(
           input,
           output,
           color,
           tolerance,
           edges,
           method,
           auto_ranges,
           num_ranges,
           edge_cleanup,
           refine,
           refine_tolerance,
           refine_block_size
         ) do
      {:ok, json} ->
        result = Jason.decode!(json)

        if result["success"] do
          IO.puts("✓ Success: #{result["output_path"]}")
        else
          IO.puts("✗ Error: #{result["error"]}")
        end

      {:error, reason} ->
        IO.puts("✗ NIF Error: #{reason}")

      other ->
        IO.puts("✗ Unexpected response: #{inspect(other)}")
    end
  end

  defp detect_bg_color(input) do
    # Sample 4 corners (top-left, top-right, bottom-left, bottom-right)
    # Using small 5x5 areas to avoid single-pixel noise.
    corners = [
      "crop=5:5:0:0",
      "crop=5:5:in_w-5:0",
      "crop=5:5:0:in_h-5",
      "crop=5:5:in_w-5:in_h-5"
    ]

    results = Enum.map(corners, fn filter ->
      case System.cmd("ffmpeg", [
             "-hide_banner",
             "-loglevel", "error",
             "-i", input,
             "-vf", filter,
             "-vframes", "1",
             "-f", "rawvideo",
             "-pix_fmt", "bgr24",
             "-"
           ], stderr_to_stdout: true) do
        {data, 0} ->
          # Calculate avg for this 5x5 block
          bytes = :erlang.binary_to_list(data)
          {b_sum, g_sum, r_sum, count} = Enum.chunk_every(bytes, 3)
          |> Enum.reduce({0, 0, 0, 0}, fn [b, g, r], {bs, gs, rs, c} ->
            {bs + b, gs + g, rs + r, c + 1}
          end)
          {b_sum / count, g_sum / count, r_sum / count}
        _ -> nil
      end
    end) |> Enum.reject(&is_nil/1)

    if results == [] do
      {:error, :detection_failed}
    else
      {b, g, r} = Enum.reduce(results, {0, 0, 0}, fn {bs, gs, rs}, {bc, gc, rc} ->
        {bc + bs, gc + gs, rc + rs}
      end)
      count = length(results)
      # Format as "B,G,R" for NIF
      {:ok, "#{round(b/count)},#{round(g/count)},#{round(r/count)}"}
    end
  end

  defp loop_op(input, output, opts) do
    method = parse_opt(opts, "--method", "pingpong")
    fade_color = parse_opt_or_nil(opts, "--fade-color")
    fade_frames = parse_opt_or_nil(opts, "--fade-frames") |> maybe_int()
    morph_steps = parse_opt_or_nil(opts, "--morph-steps") |> maybe_int()
    hold_frames = parse_opt_or_nil(opts, "--hold-frames") |> maybe_int()
    blend_mode = parse_opt_or_nil(opts, "--blend-mode")
    ramp_factor = parse_opt_or_nil(opts, "--ramp-factor") |> maybe_float()

    IO.puts("Loop: #{input} -> #{output} (method: #{method})")

    case FramerCore.Rust.create_loop(
           input,
           output,
           method,
           fade_color,
           fade_frames,
           morph_steps,
           hold_frames,
           blend_mode,
           ramp_factor
         ) do
      {:ok, json} ->
        result = Jason.decode!(json)

        if result["success"],
          do: IO.puts("Success: #{result["output_path"]}"),
          else: IO.puts("Error: #{result["error"]}")

      {:error, reason} ->
        IO.puts("NIF Error: #{inspect(reason)}")

      other ->
        IO.puts("NIF Failure: #{inspect(other)}")
    end
  end

  # --- Option parsing helpers ---

  defp parse_opt(opts, flag, default) do
    case Enum.find_index(opts, &(&1 == flag)) do
      nil -> default
      idx -> Enum.at(opts, idx + 1, default)
    end
  end

  defp parse_opt_or_nil(opts, flag) do
    case Enum.find_index(opts, &(&1 == flag)) do
      nil -> nil
      idx -> Enum.at(opts, idx + 1)
    end
  end

  defp maybe_int(nil), do: nil
  defp maybe_int(str), do: String.to_integer(str)

  defp maybe_float(nil), do: nil
  defp maybe_float(str), do: String.to_float(str)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool("1"), do: true
  defp parse_bool("0"), do: false
  defp parse_bool(other) when is_binary(other), do: String.downcase(other) == "true"

  defp help do
    IO.puts("""
    Framer CLI - Video Processing Tool

    Usage:
      mix run -e "FramerCore.CLI.main([\"info\", \"path\"])"
        Get video information

      mix run -e "FramerCore.CLI.main([\"transcode\", \"input\", \"output\"])"
        Transcode video

      mix run -e "FramerCore.CLI.main([\"process\", \"input\", \"output\", \"start\", \"end\"])"
        Process a chunk of frames

      mix run -e "FramerCore.CLI.main([\"apply-filter\", \"input\", \"output\", \"filter\"])"
        Apply video filter
        Example: hue=s=0 (grayscale), eq=brightness=0.1

      mix run -e "FramerCore.CLI.main([\"fps-boost\", \"input\", \"output\", \"--to\", \"60\"])"
        Boost video FPS to target framerate

      mix run -e "FramerCore.CLI.main([\"remove-bg\", \"input\", \"output\", \"--color\", \"0,255,0\"])"
        Remove background from video
        Options: --color, --tolerance, --edges, --method

      mix run -e "FramerCore.CLI.main([\"loop\", \"input\", \"output\", \"--method\", \"pingpong\"])"
        Create seamless video loop
        Methods: pingpong, reverse, hold, fade, blend, speedramp, periodic, auto
        Options: --fade-color, --fade-frames, --hold-frames, --blend-mode, --ramp-factor
    """)
  end
end
