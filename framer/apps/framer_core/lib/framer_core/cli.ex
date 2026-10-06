defmodule FramerCore.CLI do
  @moduledoc """
  Command line interface for the FramerCore orchestration.

  Every operation runs through the same Python Port contract
  (`remove-bg`, `fps-boost`, `loop`). The CLI only resolves the video's frame
  count / fps, submits the job to the `FramerCore.Orchestrator` and merges the
  finished chunks - it never touches pixels.

  Usage:

      mix run -e "FramerCore.CLI.main([\"info\", \"input.mp4\"])"
      mix run -e "FramerCore.CLI.main([\"remove-bg\", \"input.mp4\", \"output.webm\", \"--color\", \"0,255,0\"])"
      mix run -e "FramerCore.CLI.main([\"fps-boost\", \"input.mp4\", \"output.mp4\", \"--to\", \"60\"])"
      mix run -e "FramerCore.CLI.main([\"loop\", \"input.mp4\", \"output.mp4\", \"--method\", \"pingpong\"])"
      mix run -e "FramerCore.CLI.main([\"deform\", \"still.png\", \"output.webm\", \"--rig\", \"rig.json\"])"
  """

  alias FramerCore.Orchestrator
  alias FramerCore.PortWorker

  def main(args \\ []) do
    case args do
      ["info", path] ->
        info(path)

      ["fps-boost", input, output | opts] ->
        fps_boost(input, output, opts)

      ["fps_boost", input, output | opts] ->
        fps_boost(input, output, opts)

      ["remove-bg", input, output | opts] ->
        remove_bg(input, output, opts)

      ["remove_bg", input, output | opts] ->
        remove_bg(input, output, opts)

      ["loop", input, output | opts] ->
        loop_op(input, output, opts)

      ["deform", input, output | opts] ->
        deform(input, output, opts)

      _ ->
        help()
    end
  end

  # --- commands ---

  defp info(path) do
    IO.puts("Getting info for: #{path}")

    case run_info(path) do
      {:ok, info} ->
        IO.puts("""
        Video Info:
          Resolution: #{info["width"]}x#{info["height"]}
          FPS: #{info["fps"]}
          Frames: #{info["total_frames"]}
        """)

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp remove_bg(input, output, opts) do
    options = %{
      "color" => parse_opt_or_nil(opts, "--color"),
      "tolerance" => int_opt(opts, "--tolerance", 30),
      "edges" => int_opt(opts, "--edges", 5),
      "auto_ranges" => bool_opt(opts, "--auto-ranges", true),
      "num_ranges" => int_opt(opts, "--num-ranges", 5),
      "method" => parse_opt(opts, "--method", "color"),
      "motion_frames" => int_opt(opts, "--motion-frames", 30),
      "edge_cleanup" => int_opt(opts, "--edge-cleanup", 3),
      "adaptive_bg" => bool_opt(opts, "--adaptive-bg", false),
      "refine" => bool_opt(opts, "--refine", false),
      "refine_tolerance" => int_opt(opts, "--refine-tolerance", 45),
      "refine_block_size" => int_opt(opts, "--refine-block-size", 32),
      "force_cpu" => bool_opt(opts, "--force-cpu", false)
    }

    IO.puts("🚀 Parallel Remove BG: #{input} -> #{output}")
    submit_for_video("remove-bg", input, output, options)
  end

  defp fps_boost(input, output, opts) do
    target_fps = int_opt(opts, "--to", 60)

    case parse_opt_or_nil(opts, "--workers") do
      nil -> :ok
      workers -> FramerCore.Supervisor.set_worker_count(String.to_integer(workers))
    end

    options = %{"target_fps" => target_fps}
    IO.puts("🚀 Parallel FPS Boost: #{input} -> #{output} (target: #{target_fps}fps)")
    submit_for_video("fps-boost", input, output, options)
  end

  defp loop_op(input, output, opts) do
    options = %{
      "method" => parse_opt(opts, "--method", "auto"),
      "fade_color" => parse_opt(opts, "--fade-color", "transparent"),
      "fade_frames" => int_opt(opts, "--fade-frames", 10),
      "fade_type" => parse_opt(opts, "--fade-type", "both"),
      "morph_steps" => int_opt(opts, "--morph-steps", 10),
      "hold_frames" => int_opt(opts, "--hold-frames", 2),
      "blend_mode" => parse_opt(opts, "--blend-mode", "add"),
      "ramp_factor" => float_opt(opts, "--ramp-factor", 1.0),
      "analyze_only" => bool_opt(opts, "--analyze-only", false),
      "until" => parse_opt_or_nil(opts, "--until") |> maybe_float()
    }

    IO.puts("🚀 Loop: #{input} -> #{output} (method: #{options["method"]})")
    submit_for_video("loop", input, output, options)
  end

  defp deform(input, output, opts) do
    rig_path = parse_opt_or_nil(opts, "--rig")

    cond do
      is_nil(rig_path) ->
        IO.puts("❌ deform requires --rig <path-to-rig.json>")
        {:error, :missing_rig}

      true ->
        with {:ok, rig} <- read_rig(rig_path) do
          duration = rig["duration"] || %{}
          total_frames = int_opt(opts, "--frames", duration["frames"] || 0)
          fps = float_opt(opts, "--fps", duration["fps"] || 24.0)

          # A still-image source is looped by the op over [0, total_frames); an
          # image output renders exactly one frame so the merge stays a copy.
          total_frames =
            if image_output?(output), do: 1, else: total_frames

          if total_frames <= 0 do
            IO.puts(
              "❕ Could not determine a frame count; pass --frames or set rig.duration.frames"
            )

            {:error, :unknown_frame_count}
          else
            options = %{
              "rig" => rig_path,
              "iterations" => int_opt(opts, "--iterations", 5),
              "weights" => parse_opt_or_nil(opts, "--weights"),
              "radius_scale" => maybe_float(parse_opt_or_nil(opts, "--radius-scale")),
              "still" => true
            }

            IO.puts(
              "🚀 Deform: #{input} -> #{output} " <>
                "(rig: #{rig_path}, #{total_frames} frames @ #{fps}fps)"
            )

            submit_and_wait("deform", input, output, options,
              total_frames: total_frames,
              fps: fps
            )
          end
        end
    end
  end

  defp read_rig(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, rig} ->
            {:ok, rig}

          {:error, error} ->
            IO.puts("❌ rig is not valid JSON: #{inspect(error)}")
            {:error, :bad_rig}
        end

      {:error, reason} ->
        IO.puts("❌ could not read rig #{path}: #{inspect(reason)}")
        {:error, :bad_rig}
    end
  end

  defp image_output?(output) do
    ext = output |> Path.extname() |> String.downcase()
    ext in [".png", ".jpg", ".jpeg", ".bmp"]
  end

  # --- job plumbing ---

  defp submit_for_video(operation, input, output, options) do
    case run_info(input) do
      {:ok, info} ->
        submit_and_wait(operation, input, output, options,
          total_frames: info["total_frames"],
          fps: info["fps"]
        )

      {:error, reason} ->
        IO.puts("❌ Could not read video info: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp submit_and_wait(operation, input, output, options, submit_opts) do
    request = [operation: operation, options: options] ++ submit_opts

    case Orchestrator.submit_job(input, output, request) do
      {:ok, job_id} ->
        IO.puts("📝 Job #{job_id} submitted (#{operation}).")
        wait_for_job(job_id)

      {:error, reason} ->
        IO.puts("❌ Submit failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp wait_for_job(job_id) do
    state = Orchestrator.get_status()

    cond do
      state.job && state.job.id == job_id && state.job.status == :completed ->
        IO.puts("🎉 Job completed successfully!")
        merge_job(state.job, state.completed_chunks)

      state.job && state.job.id == job_id && state.job.status == :failed ->
        IO.puts(
          "❌ Job failed: #{length(state.failed_chunks)} chunk(s) could not be processed; " <>
            "refusing to merge an incomplete result."
        )

        {:error, :job_failed}

      true ->
        Process.sleep(500)
        wait_for_job(job_id)
    end
  end

  defp merge_job(job, chunks) do
    IO.puts("🔗 Merging #{length(chunks)} chunk(s) into #{job.output_path}")

    case FramerCore.Operations.merge_job(job, chunks) do
      {:ok, %{"output" => output}} ->
        IO.puts("✓ Success: #{output}")
        {:ok, output}

      {:error, reason} ->
        IO.puts("❌ Merge failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_info(path) do
    PortWorker.run_once(%{"op" => "info", "input" => path})
  end

  # --- option parsing helpers ---

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

  defp int_opt(opts, flag, default),
    do: opts |> parse_opt(flag, to_string(default)) |> String.to_integer()

  defp float_opt(opts, flag, default) do
    value = parse_opt(opts, flag, to_string(default))

    case Float.parse(value) do
      {float, _} -> float
      :error -> default
    end
  end

  defp bool_opt(opts, flag, default) do
    opts |> parse_opt(flag, to_string(default)) |> parse_bool()
  end

  defp maybe_float(nil), do: nil

  defp maybe_float(str) do
    case Float.parse(str) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool("1"), do: true
  defp parse_bool("0"), do: false
  defp parse_bool(other) when is_binary(other), do: String.downcase(other) == "true"

  defp help do
    IO.puts("""
    Framer CLI - video processing through the Python Port operation layer

    Usage:
      FramerCore.CLI.main(["info", "path"])
      FramerCore.CLI.main(["remove-bg", "input", "output", "--color", "0,255,0"])
        Options: --color, --tolerance, --edges, --auto-ranges, --num-ranges,
                 --method, --motion-frames, --edge-cleanup, --adaptive-bg,
                 --refine, --refine-tolerance, --refine-block-size, --force-cpu
      FramerCore.CLI.main(["fps-boost", "input", "output", "--to", "60", "--workers", "4"])
      FramerCore.CLI.main(["loop", "input", "output", "--method", "pingpong"])
        Methods: auto, pingpong, morph, periodic, hold, fade, blend, reverse, speedramp
      FramerCore.CLI.main(["deform", "still.png", "output.webm", "--rig", "rig.json"])
        Options: --rig, --frames, --fps, --iterations, --weights, --radius-scale
    """)
  end
end
