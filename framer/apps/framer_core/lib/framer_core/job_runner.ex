defmodule FramerCore.JobRunner do
  @moduledoc """
  Runs one catalog operation through the orchestrator.

  This is the single execution path behind `framer <operation>`: it takes the
  parsed invocation, resolves how many frames the job covers (probing the
  input with the Port `info` op, or reading the rig document's `duration`),
  submits the job to `FramerCore.Orchestrator` and merges the finished chunks
  into the requested output. Progress is reported by the orchestrator itself
  as each chunk finishes.

  Nothing here knows what an operation does to the pixels; the BEAM only ever
  carries paths, a frame range and JSON options to the Python Port worker, and
  the chunked/parallel path is the default rather than a special invocation.

  Output discipline: diagnostics go to stderr, so stdout carries exactly one
  line on success - the output path. An agent can therefore treat the exit code
  plus stdout as the machine contract.
  """

  alias FramerCore.Catalog
  alias FramerCore.Operations
  alias FramerCore.Orchestrator
  alias FramerCore.PortWorker

  @poll_interval 250

  @doc """
  Run `operation` with the raw argv that followed it on the command line.
  """
  @spec run(Catalog.operation(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(%{} = operation, argv) do
    FramerCore.ensure_started!()

    case FramerCore.Args.parse(operation, argv) do
      {:ok, parsed} -> execute(operation, parsed)
      {:error, message} -> {:error, message}
    end
  end

  @doc "Probe a media file through the Port `info` operation."
  @spec probe(String.t()) :: {:ok, map()} | {:error, term()}
  def probe(path) do
    FramerCore.ensure_started!()
    PortWorker.run_once(%{"op" => "info", "input" => path})
  end

  @doc "Trim a worker error to something a caller can act on."
  @spec brief(term()) :: String.t()
  def brief(reason), do: do_brief(reason)

  defp execute(%{} = operation, %{positional: positional, options: options}) do
    input = positional["input"]
    output = positional["output"]

    workers = Map.get(options, "workers")
    options = Map.delete(options, "workers")

    with {:ok, input} <- require_readable(input),
         {:ok, output} <- require_writable_dir(output),
         {:ok, %{total_frames: total_frames, fps: fps}} <-
           frame_info(operation, input, output, options),
         :ok <- scale_players(workers),
         {:ok, job_id} <- submit(operation, input, output, options, total_frames, fps) do
      await_job(job_id)
    end
  end

  # A job is one file in, one file out: the frame count is the only thing that
  # needs resolving before the orchestrator can chunk it.

  # A bad path is the caller's problem, and it is far kinder to say so here
  # than to hand the worker a file it cannot open and quote an FFmpeg error
  # back at whoever ran the command.
  defp require_readable(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, "no such file: #{path}"}
    end
  end

  defp require_writable_dir(path) do
    dir = Path.dirname(Path.expand(path))

    if File.dir?(dir) do
      {:ok, path}
    else
      {:error, "output directory does not exist: #{dir}"}
    end
  end

  # --- frame count / fps resolution ---

  defp frame_info(%{frames: :info} = operation, input, _output, _options) do
    case probe(input) do
      {:ok, %{"total_frames" => total_frames, "fps" => fps}} when is_number(total_frames) ->
        if total_frames > 0 do
          {:ok, %{total_frames: total_frames, fps: fps}}
        else
          {:error,
           "could not determine a frame count for #{input}; #{operation.name} needs a readable video"}
        end

      {:ok, info} ->
        {:error, "the Port info probe returned no frame count for #{input}: #{inspect(info)}"}

      {:error, reason} ->
        {:error, "could not read #{input}: #{brief(reason)}"}
    end
  end

  defp frame_info(%{frames: {:rig, key}} = _operation, _input, output, options) do
    with {:ok, rig_path} <- required_path(options, key),
         {:ok, rig} <- read_rig(rig_path) do
      duration = rig["duration"] || %{}
      fps = options["fps"] || duration["fps"] || 24.0
      total_frames = options["frames"] || duration["frames"] || 0

      # A still-image source is looped by the op over [0, total_frames); an
      # image output renders exactly one frame so the merge stays a copy.
      total_frames = if image_output?(output), do: 1, else: total_frames

      if total_frames > 0 do
        {:ok, %{total_frames: total_frames, fps: fps}}
      else
        {:error, "no frame count in #{rig_path}: set --frames or rig.duration.frames"}
      end
    end
  end

  defp required_path(options, key) do
    case Map.get(options, key) do
      nil -> {:error, "missing required option --#{key}"}
      path -> {:ok, path}
    end
  end

  defp image_output?(output) do
    output
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in ~w(.png .jpg .jpeg .bmp)))
  end

  # The rig is a versioned JSON document; it is validated by the op that reads
  # it, so here it is only checked for being readable and being a JSON object.
  defp read_rig(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, rig} when is_map(rig) -> {:ok, rig}
          {:ok, _} -> {:error, "#{path} is not a rig document (expected a JSON object)"}
          {:error, reason} -> {:error, "#{path} is not valid JSON: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "could not read rig #{path}: #{inspect(reason)}"}
    end
  end

  # --- submission, progress and merge ---

  defp scale_players(nil), do: :ok

  defp scale_players(workers) when is_integer(workers) and workers > 0,
    do: FramerCore.Supervisor.set_worker_count(workers)

  defp scale_players(workers) do
    {:error, "--workers expects a positive integer, got #{inspect(workers)}"}
  end

  defp submit(%{} = operation, input, output, options, total_frames, fps) do
    request = [operation: operation.name, options: options, total_frames: total_frames, fps: fps]

    log("🚀 #{operation.name}: #{input} -> #{output}")

    case Orchestrator.submit_job(input, output, request) do
      {:ok, job_id} ->
        log("📝 Job #{job_id} submitted (#{operation.name}, #{total_frames} frames @ #{fps}fps)")
        {:ok, job_id}

      {:error, reason} ->
        {:error, "submit failed: #{inspect(reason)}"}
    end
  end

  # Progress is reported by the orchestrator itself (it logs every finished
  # chunk, on stderr), so this loop only waits for a terminal job status.
  defp await_job(job_id) do
    state = Orchestrator.get_status()

    cond do
      state.job && state.job.id == job_id && state.job.status == :completed ->
        log("🎉 Job completed successfully!")
        merge(state.job, state.completed_chunks)

      state.job && state.job.id == job_id && state.job.status == :failed ->
        {:error,
         "job failed: #{length(state.failed_chunks)} of #{state.total_chunks} chunk(s) could " <>
           "not be processed; refusing to merge an incomplete result"}

      true ->
        Process.sleep(@poll_interval)
        await_job(job_id)
    end
  end

  defp merge(job, chunks) do
    log("🔗 Merging #{length(chunks)} chunk(s) into #{job.output_path}")

    case Operations.merge_job(job, chunks) do
      {:ok, %{"output" => output}} ->
        emit(output)
        {:ok, output}

      {:error, reason} ->
        {:error, "merge failed: #{brief(reason)}"}
    end
  end

  # A worker error can be a whole FFmpeg command line; the caller needs to know
  # what failed, not how the command was spelled.
  @max_reason_length 200

  defp do_brief(reason) when is_binary(reason) do
    if String.length(reason) > @max_reason_length do
      String.slice(reason, 0, @max_reason_length) <> "..."
    else
      reason
    end
  end

  defp do_brief(reason), do: inspect(reason)

  # Diagnostics and progress belong on stderr; stdout is the machine contract.
  defp log(message), do: IO.puts(:stderr, message)
  defp emit(message), do: IO.puts(message)
end
