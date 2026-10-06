defmodule FramerWeb.Renderer do
  @moduledoc """
  Editor -> engine bridge.

  Two entry points, both over the existing Port contract (paths, frame ranges
  and JSON options; the BEAM never sees pixels):

    * `render_frame/3` runs a single-frame `deform` through a throwaway Port
      worker and returns the PNG bytes - the editor's "Render this frame at
      full quality" action and the golden-parity reference.
    * `submit_export/2` submits a chunked `deform` job to the existing
      `FramerCore.Orchestrator`, then watches it to completion and merges the
      chunks into the project's `output.*`. Progress is broadcast on the
      project's PubSub topic.

  The final render is authoritative: the interactive preview is only a proxy
  of the same fixed-point linear-blend-skinning math.
  """

  require Logger

  alias FramerCore.Operations
  alias FramerCore.Orchestrator
  alias FramerCore.PortWorker
  alias FramerWeb.Rig
  alias FramerWeb.RigStore

  @poll_interval 400
  @default_timeout 300_000

  @doc "PubSub topic for a project's render/export progress."
  def topic(rig_id), do: "rig:#{rig_id}"

  @doc """
  Render one frame of `rig` at full quality and return `{:ok, png_binary}`.

  The in-memory rig is written to a private temp file so the engine reads
  exactly what the editor is showing, even before the next autosave lands.
  """
  def render_frame(rig, frame, opts \\ []) do
    with {:ok, source} <- source_path(rig) do
      frame = to_int(frame) || 0
      workspace = workspace_dir(rig)
      rig_path = Path.join(workspace, "render_rig.json")
      output = Path.join(workspace, "frame_#{frame}_#{System.unique_integer([:positive])}.png")

      File.mkdir_p!(workspace)
      File.write!(rig_path, Jason.encode!(rig))

      request = %{
        "op" => "deform",
        "input" => source,
        "output" => output,
        "start_frame" => frame,
        "end_frame" => frame,
        "fps" => Rig.fps(rig),
        "options" => %{
          "rig" => rig_path,
          "still" => true,
          "iterations" => opts[:iterations] || 6
        }
      }

      try do
        case PortWorker.run_once(request, Keyword.get(opts, :timeout, @default_timeout)) do
          {:ok, _response} ->
            case File.read(output) do
              {:ok, binary} -> {:ok, binary}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      after
        File.rm(output)
      end
    end
  end

  @doc """
  Submit a chunked deform export for `rig`.

  Returns `{:ok, %{job_id: id, output: path, format: format}}` and starts a
  background watcher that merges the finished chunks when the job completes.
  """
  def submit_export(rig, opts \\ []) do
    with {:ok, source} <- source_path(rig),
         :ok <- ensure_saved(rig) do
      format = opts[:format] || "webm"
      output = RigStore.output_path(rig["id"], format)
      frames = to_int(opts[:frames]) || Rig.frame_count(rig)
      fps = opts[:fps] || Rig.fps(rig)

      options =
        %{
          "rig" => RigStore.rig_path(rig["id"]),
          "still" => true,
          "iterations" => opts[:iterations] || 5
        }
        |> maybe_put("weights", opts[:weights])

      case Orchestrator.submit_job(source, output,
             operation: "deform",
             options: options,
             total_frames: frames,
             fps: to_float(fps)
           ) do
        {:ok, job_id} ->
          start_watcher(job_id, rig["id"], output)
          {:ok, %{job_id: job_id, output: output, format: format}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Merge a finished job's chunks into `output` and return the output path."
  def merge(job, chunks) do
    case Operations.merge_job(job, chunks) do
      {:ok, %{"output" => output}} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- internals ---

  defp start_watcher(job_id, rig_id, output) do
    Task.start(fn -> watch(job_id, rig_id, output) end)
  end

  defp watch(job_id, rig_id, output, attempts \\ 750) do
    state = Orchestrator.get_status()

    cond do
      state.job && state.job.id == job_id && state.job.status == :completed ->
        result = merge(state.job, state.completed_chunks)
        broadcast(rig_id, event(job_id, :completed, result, output, state))

      state.job && state.job.id == job_id && state.job.status == :failed ->
        broadcast(rig_id, event(job_id, :failed, {:error, :job_failed}, output, state))

      attempts <= 0 ->
        broadcast(rig_id, event(job_id, :failed, {:error, :timeout}, output, state))

      true ->
        Process.sleep(@poll_interval)
        watch(job_id, rig_id, output, attempts - 1)
    end
  end

  defp event(job_id, status, result, output, state) do
    %{
      job_id: job_id,
      status: status,
      output: output,
      result: result,
      completed_chunks: length(state.completed_chunks),
      failed_chunks: length(state.failed_chunks),
      total_chunks: state.total_chunks
    }
  end

  defp broadcast(rig_id, payload) do
    Phoenix.PubSub.broadcast(FramerWeb.PubSub, topic(rig_id), {:export, payload})
  end

  defp ensure_saved(rig) do
    case RigStore.save(rig) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_path(rig) do
    path = get_in(rig, ["source", "path"])

    cond do
      is_binary(path) and File.exists?(path) -> {:ok, path}
      is_binary(rig["id"]) -> fallback_source(rig["id"])
      true -> {:error, :missing_source}
    end
  end

  defp fallback_source(id) do
    case RigStore.source_path(id) do
      nil -> {:error, :missing_source}
      path -> {:ok, path}
    end
  end

  defp workspace_dir(rig) do
    id = rig["id"] || "scratch"
    Path.join(RigStore.project_dir(id), ".render")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value),
    do:
      (case Integer.parse(value) do
         {int, _} -> int
         :error -> nil
       end)

  defp to_int(_), do: nil

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value),
    do:
      (case Float.parse(value) do
         {float, _} -> float
         :error -> nil
       end)

  defp to_float(_), do: nil
end
