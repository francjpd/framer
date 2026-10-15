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

  `split_character/2` is the bridge's third entry point and shares the same
  contract: it materialises the character layer of a split rig with the engine's
  existing background-removal segmentation.

  A split rig (`rig.layers.split`) renders through the same `deform` operation
  as ever - the rig document tells the engine which character layer to deform -
  so the final render is authoritative for the layering exactly as it is for the
  math. The interactive preview is only a proxy of the same layering: it fetches
  the engine-materialised cut-out and its opaque background plate when present
  (reflecting transparency when the background layer is removed).
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
  Materialise the character layer of a split rig and return `{:ok, path}`.

  This is the editor's "extract the character" action. It runs the engine's
  existing background-removal segmentation over the still through the same Port
  contract every other render uses - the BEAM still only ever sends paths, a
  frame range and JSON options - and writes `<project>/character.png`, the
  cut-out whose alpha is the character mask, next to the opaque background plate
  the engine composites it over.

  The render that produces it is frame 0 of the very rig being split, so the
  composited still the editor shows afterwards is exactly what the first render
  will produce. The response carries the materialised path, which is what the
  editor records in `rig.layers.character` and persists.
  """
  def split_character(rig, opts \\ []) do
    with {:ok, source} <- source_path(rig) do
      workspace = workspace_dir(rig)
      rig_path = Path.join(workspace, "split_rig.json")
      output = Path.join(workspace, "split_#{System.unique_integer([:positive])}.png")

      File.mkdir_p!(workspace)
      File.write!(rig_path, Jason.encode!(rig))

      request = %{
        "op" => "deform",
        "input" => source,
        "output" => output,
        "start_frame" => 0,
        "end_frame" => 0,
        "fps" => Rig.fps(rig),
        "options" => %{
          "rig" => rig_path,
          "still" => true,
          "iterations" => opts[:iterations] || 6
        }
      }

      try do
        case PortWorker.run_once(request, Keyword.get(opts, :timeout, @default_timeout)) do
          {:ok, %{"character" => path}} when is_binary(path) ->
            {:ok, path}

          {:ok, _response} ->
            {:error, :layer_not_materialised}

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

      workspace = workspace_dir(rig)
      export_dir = Path.join(workspace, "export_#{System.unique_integer([:positive])}")
      File.mkdir_p!(export_dir)

      snapshotted_source = Path.join(export_dir, Path.basename(source))
      File.cp!(source, snapshotted_source)

      snapshotted_rig_path = Path.join(export_dir, "rig.json")
      File.write!(snapshotted_rig_path, Jason.encode!(rig))

      snapshot_layer_files(rig, export_dir)

      options =
        %{
          "rig" => snapshotted_rig_path,
          "still" => true,
          "iterations" => opts[:iterations] || 5
        }
        |> maybe_put("weights", opts[:weights])

      case Orchestrator.submit_job(snapshotted_source, output,
             operation: "deform",
             options: options,
             total_frames: frames,
             fps: to_float(fps)
           ) do
        {:ok, job_id} ->
          start_watcher(job_id, rig["id"], output, export_dir)
          {:ok, %{job_id: job_id, output: output, format: format}}

        {:error, reason} ->
          File.rm_rf(export_dir)
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

  defp start_watcher(job_id, rig_id, output, export_dir) do
    Task.start(fn -> watch(job_id, rig_id, output, export_dir) end)
  end

  defp watch(job_id, rig_id, output, export_dir, attempts \\ 750) do
    state = Orchestrator.get_status()

    cond do
      state.job && state.job.id == job_id && state.job.status == :completed ->
        event = completion_event(job_id, merge(state.job, state.completed_chunks), output, state)
        if export_dir, do: File.rm_rf(export_dir)
        broadcast(rig_id, event)

      state.job && state.job.id == job_id && state.job.status == :failed ->
        if export_dir, do: File.rm_rf(export_dir)
        broadcast(rig_id, event(job_id, :failed, {:error, :job_failed}, output, state))

      attempts <= 0 ->
        if export_dir, do: File.rm_rf(export_dir)
        broadcast(rig_id, event(job_id, :failed, {:error, :timeout}, output, state))

      true ->
        Process.sleep(@poll_interval)
        watch(job_id, rig_id, output, export_dir, attempts - 1)
    end
  end

  @doc false
  def completion_event(job_id, {:ok, _merged}, output, state),
    do: event(job_id, :completed, {:ok, output}, output, state)

  def completion_event(job_id, {:error, reason}, output, state),
    do: event(job_id, :failed, {:error, reason}, output, state)

  defp event(job_id, status, result, output, state) do
    %{
      job_id: job_id,
      status: status,
      output: output,
      result: result,
      error: event_error(result),
      completed_chunks: length(state.completed_chunks),
      failed_chunks: length(state.failed_chunks),
      total_chunks: state.total_chunks
    }
  end

  defp event_error({:error, reason}) when is_binary(reason), do: reason
  defp event_error({:error, reason}), do: inspect(reason)
  defp event_error(_), do: nil

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
    id = rig["id"]

    case project_root(id) do
      :error ->
        {:error, :missing_source}

      {:ok, root} ->
        case declared_source(rig, root) do
          {:ok, path} ->
            if File.exists?(path), do: {:ok, path}, else: fallback_source(id)

          {:error, :escaping_path} ->
            {:error, :escaping_path}

          :none ->
            fallback_source(id)
        end
    end
  end

  defp project_root(id) when is_binary(id), do: {:ok, RigStore.project_dir(id)}
  defp project_root(_), do: :error

  defp declared_source(rig, root) do
    case rig["source"] do
      %{"path" => path} when is_binary(path) -> Rig.confine_to_project(path, root)
      _ -> :none
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

  defp snapshot_layer_files(rig, export_dir) do
    id = rig["id"]

    if id do
      project_dir = RigStore.project_dir(id)

      if Rig.has_character_layer?(rig) do
        char_rel = Rig.character_layer(rig) || Rig.layer_filename()
        char_src = RigStore.character_layer_path(id)

        if char_src && File.exists?(char_src) do
          char_dest = Path.join(export_dir, char_rel)
          File.mkdir_p!(Path.dirname(char_dest))
          File.cp!(char_src, char_dest)
        end

        default_layer_src = Path.join(project_dir, Rig.layer_filename())

        if File.exists?(default_layer_src) && default_layer_src != char_src do
          default_dest = Path.join(export_dir, Rig.layer_filename())
          File.mkdir_p!(Path.dirname(default_dest))
          File.cp!(default_layer_src, default_dest)
        end
      end

      if Rig.has_background_layer?(rig) do
        bg_rel = Rig.background_layer(rig) || Rig.plate_filename()
        plate_src = RigStore.plate_path(id) || Path.join(project_dir, bg_rel)

        if plate_src && File.exists?(plate_src) do
          plate_dest = Path.join(export_dir, bg_rel)
          File.mkdir_p!(Path.dirname(plate_dest))
          File.cp!(plate_src, plate_dest)
        end
      end
    end
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
