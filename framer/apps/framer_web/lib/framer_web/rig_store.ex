defmodule FramerWeb.RigStore do
  @moduledoc """
  Filesystem-first persistence for editor rigs.

  The design deliberately keeps Ecto/Postgres disabled: one directory per
  project under the configured projects root, holding the source still, the
  versioned `rig.json` and the exported result. That matches how the engine
  reads a rig (by path) and gives the editor a durable artifact without a
  database.

      <root>/<rig-id>/
        source.png      # uploaded still
        rig.json        # framer.rig v1 (the engine-facing contract)
        output.webm     # merged export, once rendered

  Rig ids are opaque and restricted to a URL-safe alphabet so an `:id` path
  segment can never escape the projects root.
  """

  alias FramerWeb.ImageInfo
  alias FramerWeb.Rig

  @id_regex ~r/^[A-Za-z0-9_-]+$/
  @result_names ["output.webm", "output.mp4", "output.mov", "output.gif"]

  @doc "Root directory holding every project."
  def root do
    Application.get_env(:framer_web, :projects_dir) ||
      Path.join(:code.priv_dir(:framer_web), "projects")
  end

  @doc "Absolute path of a project directory."
  def project_dir(id) when is_binary(id) do
    Path.join(root(), id)
  end

  @doc "Absolute path of a project's `rig.json`."
  def rig_path(id), do: Path.join(project_dir(id), "rig.json")

  @doc """
  Absolute path of a project's materialised character layer, if it exists.

  The engine writes this when a split rig first renders; it is the cut-out the
  rig deforms. The path is the one the rig document declares, falling back to
  the default name. Returns `nil` when the layer is removed (`false`) or does
  not exist.
  """
  def character_layer_path(id) do
    with :ok <- validate_id(id) do
      case load(id) do
        {:ok, rig} ->
          if get_in(rig, ["layers", "character"]) != false do
            path = character_layer_for(rig, id)
            if File.exists?(path), do: path
          end

        {:error, _} ->
          path = Path.join(project_dir(id), Rig.layer_filename())
          if File.exists?(path), do: path
      end
    else
      _ -> nil
    end
  end

  @doc """
  Absolute path of a project's background plate, if it exists.

  The engine materialises it beside the cut-out at split time: an opaque copy of
  the still whose character area is reconstructed from the surrounding
  background, so the layer the rig never warps covers every pixel. The character
  layer is composited over it with a plain source-over, which is what the
  editor's preview fetches to agree with the export. Returns `nil` when the layer
  is removed (`false`) or does not exist.
  """
  def plate_path(id) do
    with :ok <- validate_id(id) do
      case load(id) do
        {:ok, rig} ->
          if get_in(rig, ["layers", "background"]) != false do
            bg = Rig.background_layer(rig) || Rig.plate_filename()
            path = Path.join(project_dir(id), bg)
            if File.exists?(path), do: path
          end

        {:error, _} ->
          path = Path.join(project_dir(id), Rig.plate_filename())
          if File.exists?(path), do: path
      end
    else
      _ -> nil
    end
  end

  @doc "Absolute path of a project's materialised patch layer, if it exists."
  def patch_path(id) do
    with :ok <- validate_id(id) do
      path = Path.join(project_dir(id), Rig.patch_filename())
      if File.exists?(path), do: path
    else
      _ -> nil
    end
  end

  @doc """
  A cache-busting version for the materialised patch layer.

  The patch is rebuilt whenever the rig it came from changes, so the file's
  timestamp is what tells the editor's preview that the bytes behind the same
  URL are new.
  """
  def patch_version(id) do
    case patch_path(id) do
      nil ->
        nil

      path ->
        case File.stat(path) do
          {:ok, stat} -> inspect(stat.mtime)
          _ -> nil
        end
    end
  end

  @doc "Replace a project's layer (:source, :character, or :background) with a new image."
  def replace_layer(id, :source, binary, filename),
    do: replace_layer(id, "source", binary, filename)

  def replace_layer(id, :character, binary, filename),
    do: replace_layer(id, "character", binary, filename)

  def replace_layer(id, :background, binary, filename),
    do: replace_layer(id, "background", binary, filename)

  def replace_layer(id, "source", binary, filename) when is_binary(binary) do
    with :ok <- validate_id(id),
         {:ok, info} <- ImageInfo.read(binary),
         {:ok, rig} <- load(id) do
      ext = extension(filename, binary, info.format)
      dest_name = "source_replaced.#{ext}"
      dest_path = Path.join(project_dir(id), dest_name)
      File.write!(dest_path, binary)

      rig =
        rig
        |> put_in(["source", "path"], dest_name)
        |> put_in(["canvas", "width"], info.width)
        |> put_in(["canvas", "height"], info.height)

      save(rig)
    end
  end

  def replace_layer(id, "character", binary, filename) when is_binary(binary) do
    with :ok <- validate_id(id),
         {:ok, info} <- ImageInfo.read(binary),
         {:ok, rig} <- load(id) do
      ext = extension(filename, binary, info.format)
      dest_name = "character_replaced.#{ext}"
      dest_path = Path.join(project_dir(id), dest_name)
      File.write!(dest_path, binary)

      rig =
        rig
        |> then(fn r -> if Rig.split?(r), do: r, else: Rig.enable_split(r) end)
        |> Rig.set_character_layer(dest_name)

      save(rig)
    end
  end

  def replace_layer(id, "background", binary, filename) when is_binary(binary) do
    with :ok <- validate_id(id),
         {:ok, info} <- ImageInfo.read(binary),
         {:ok, rig} <- load(id) do
      ext = extension(filename, binary, info.format)
      dest_name = "background_replaced.#{ext}"
      dest_path = Path.join(project_dir(id), dest_name)
      File.write!(dest_path, binary)

      rig =
        rig
        |> then(fn r -> if Rig.split?(r), do: r, else: Rig.enable_split(r) end)
        |> Rig.set_background_layer(dest_name)

      save(rig)
    end
  end

  @doc """
  Remove a split rig's materialised layers, so the engine recomputes them.

  A re-extraction has to drop every file the engine could resolve for the rig:
  the declared character path and the default name it falls back to once the
  document stops declaring one, plus the plate that was built from them.
  """
  def remove_character_layer(id) do
    with :ok <- validate_id(id),
         {:ok, rig} <- load(id) do
      [
        character_layer_for(rig, id),
        Path.join(project_dir(id), Rig.layer_filename()),
        Path.join(project_dir(id), Rig.plate_filename())
      ]
      |> Enum.each(&File.rm/1)

      :ok
    else
      _ -> :ok
    end
  end

  defp character_layer_for(rig, id) do
    Path.join(project_dir(id), Rig.character_layer(rig) || Rig.layer_filename())
  end

  @doc "Absolute path of a project's exported result, if it exists."
  def result_path(id) do
    with :ok <- validate_id(id) do
      Enum.find_value(@result_names, fn name ->
        path = Path.join(project_dir(id), name)
        if File.exists?(path), do: path
      end)
    else
      _ -> nil
    end
  end

  @doc "Absolute path a merged export should be written to for `format`."
  def output_path(id, format \\ "webm") do
    ext =
      case format do
        f when f in ["mp4", "mov", "gif", "webm"] -> f
        _ -> "webm"
      end

    Path.join(project_dir(id), "output.#{ext}")
  end

  @doc "Find the project's source still, if any."
  def source_path(id) do
    with :ok <- validate_id(id) do
      project_dir(id)
      |> Path.join("source.*")
      |> Path.wildcard()
      |> List.first()
    else
      _ -> nil
    end
  end

  @doc "List saved rigs, newest first."
  def list do
    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&valid_id?/1)
        |> Enum.flat_map(fn id ->
          case load(id) do
            {:ok, rig} -> [summary(id, rig)]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Create a project from an uploaded still. Returns `{:ok, rig}`."
  def create_from_source(binary, filename, opts \\ []) when is_binary(binary) do
    with {:ok, info} <- ImageInfo.read(binary) do
      id = opts[:id] || UUID.uuid4()
      ext = extension(filename, binary, info.format)
      source = write_source!(id, binary, ext)

      rig =
        Rig.new(info.width, info.height,
          id: id,
          name: opts[:name] || default_name(filename),
          source_path: source
        )

      with {:ok, rig} <- save(rig), do: {:ok, rig}
    end
  end

  @doc "Persist a rig document, validating it first. Returns `{:ok, rig}`."
  def save(%{"id" => id} = rig) do
    with :ok <- validate_id(id),
         {:ok, rig} <- Rig.validate(rig, allow_empty_bones: true, project_dir: project_dir(id)) do
      dir = project_dir(id)
      File.mkdir_p!(dir)

      body = Jason.encode!(rig, pretty: true)
      target = Path.join(dir, "rig.json")
      temp = Path.join(dir, ".rig.json.tmp.#{System.unique_integer([:positive])}")
      File.write!(temp, body)
      File.rename!(temp, target)
      {:ok, rig}
    end
  end

  def save(_rig), do: {:error, :missing_id}

  @doc "Load and validate a stored rig."
  def load(id) do
    with :ok <- validate_id(id) do
      path = rig_path(id)

      case File.read(path) do
        {:ok, body} -> decode(body, project_dir(id))
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Delete a project's directory - source still, `rig.json` and any exported
  result. Succeeds when the directory is already missing, so a repeat delete is
  harmless.
  """
  def delete(id) do
    with :ok <- validate_id(id), do: File.rm_rf(project_dir(id))
  end

  @doc "Write the source still for a project and return its path."
  def write_source!(id, binary, ext) do
    with :ok <- validate_id(id) do
      dir = project_dir(id)
      File.mkdir_p!(dir)

      for existing <- Path.wildcard(Path.join(dir, "source.*")), do: File.rm(existing)

      path = Path.join(dir, "source.#{ext}")
      File.write!(path, binary)
      path
    end
  end

  @doc "Whether a string is a safe project id."
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_regex, id)

  @doc "Raise unless the id is safe."
  def validate_id(id) do
    if valid_id?(id), do: :ok, else: {:error, :invalid_id}
  end

  defp decode(body, project_dir) do
    case Jason.decode(body) do
      {:ok, rig} ->
        case Rig.validate(rig, allow_empty_bones: true, project_dir: project_dir) do
          {:ok, _} -> {:ok, rig}
          {:error, reason} -> {:error, {:invalid_rig, reason}}
        end

      {:error, error} ->
        {:error, {:invalid_json, error}}
    end
  end

  defp summary(id, rig) do
    %{
      id: id,
      name: rig["name"] || id,
      canvas: Rig.canvas(rig),
      bones: length(Rig.bones(rig)),
      frames: Rig.frame_count(rig),
      fps: Rig.fps(rig),
      has_source: source_path(id) != nil,
      has_result: result_path(id) != nil
    }
  end

  defp extension(filename, _binary, format) do
    from_name =
      filename
      |> to_string()
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    cond do
      from_name in ["png", "jpg", "jpeg", "webp", "bmp", "gif"] -> from_name
      format == :jpeg -> "jpg"
      true -> to_string(format)
    end
  end

  defp default_name(nil), do: "Untitled rig"

  defp default_name(filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> Path.rootname()
  end
end
