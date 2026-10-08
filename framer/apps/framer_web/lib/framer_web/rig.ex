defmodule FramerWeb.Rig do
  @moduledoc """
  Rig document model for the editor (schema `framer.rig` version 1).

  This module is the Elixir mirror of `core/deform.py`'s rig schema and bone
  math. It is deliberately pure: it builds and mutates the versioned rig JSON
  document, computes the display control mesh and per-vertex weights, and
  interpolates keyframes. It never touches pixels or the Port - `FramerWeb.RigStore`
  persists the result and the engine's Python validator remains authoritative at
  render time. `validate/2` confines `source.path` to the project directory when
  given `:project_dir`.

  The document is a `%{String.t() => term()}` map with JSON string keys so it
  round-trips through Jason unchanged. Weights are always *derived* from the
  bones; they are never treated as authoritative input.
  """

  @schema "framer.rig"
  @version 1

  @default_fps 24
  @default_frames 48
  @default_power 2.0
  @default_radius 10.0
  @falloffs ~w(smooth linear hard)

  @type rig :: map()
  @type point :: {number(), number()}

  def schema, do: @schema
  def version, do: @version
  def falloffs, do: @falloffs

  # ---------------------------------------------------------------------------
  # construction
  # ---------------------------------------------------------------------------

  @doc """
  Build a fresh, empty `framer.rig` v1 document.

  `opts` may set `:id`, `:source_path`, `:fps`, `:frames` and `:name`.
  """
  def new(width, height, opts \\ []) when is_integer(width) and is_integer(height) do
    %{
      "schema" => @schema,
      "version" => @version,
      "id" => opts[:id] || UUID.uuid4(),
      "name" => opts[:name] || "Untitled rig",
      "canvas" => %{"width" => width, "height" => height},
      "source" => %{
        "kind" => "image",
        "path" => opts[:source_path],
        "frame" => 0
      },
      "duration" => %{
        "fps" => opts[:fps] || @default_fps,
        "frames" => opts[:frames] || @default_frames
      },
      "mesh" => %{"mode" => "grid", "vertices" => [], "triangles" => [], "weights" => []},
      "bones" => [],
      "bind" => %{"mode" => "auto", "power" => @default_power, "radius_scale" => 1.0},
      "keyframes" => [],
      "playback" => %{"loop" => true}
    }
  end

  def canvas(%{"canvas" => canvas}), do: canvas
  def canvas(_), do: %{"width" => 0, "height" => 0}

  def width(rig), do: rig |> canvas() |> Map.get("width", 0)
  def height(rig), do: rig |> canvas() |> Map.get("height", 0)

  def bones(%{"bones" => bones}) when is_list(bones), do: bones
  def bones(_), do: []

  def keyframes(%{"keyframes" => keyframes}) when is_list(keyframes), do: keyframes
  def keyframes(_), do: []

  def bone(rig, id), do: Enum.find(bones(rig), &(&1["id"] == id))

  def duration(%{"duration" => duration}) when is_map(duration) do
    %{
      "fps" => Map.get(duration, "fps", @default_fps),
      "frames" => Map.get(duration, "frames", @default_frames)
    }
  end

  def duration(_), do: %{"fps" => @default_fps, "frames" => @default_frames}

  def fps(rig), do: rig |> duration() |> Map.fetch!("fps") |> to_number()
  def frame_count(rig), do: rig |> duration() |> Map.fetch!("frames") |> to_integer()

  @doc """
  A conservative, human-readable validation mirroring `core/deform.validate_rig/1`.

  Returns `{:ok, rig}` or `{:error, reason}`. The Python validator is still the
  authority at render time; this keeps the editor from persisting or shipping a
  document the engine will reject.
  """
  def validate(rig, opts \\ []) do
    allow_empty = Keyword.get(opts, :allow_empty_bones, false)
    project_dir = Keyword.get(opts, :project_dir)

    case rig do
      %{"schema" => @schema, "version" => @version} ->
        with {:ok, _} <- validate_name(rig),
             {:ok, _} <- validate_canvas(rig),
             {:ok, bones} <- validate_bones(rig, allow_empty),
             {:ok, _} <- validate_keyframes(rig, bones),
             {:ok, _} <- validate_bind(rig),
             {:ok, _} <- validate_duration(rig),
             {:ok, _} <- validate_source(rig, project_dir) do
          {:ok, rig}
        end

      %{"schema" => schema} when schema != @schema ->
        {:error, "rig.schema must be #{inspect(@schema)}, got #{inspect(schema)}"}

      %{"version" => version} when version != @version ->
        {:error, "unsupported rig version #{inspect(version)}; expected #{@version}"}

      _ ->
        {:error, "rig must be a JSON object with schema #{inspect(@schema)}"}
    end
  end

  defp validate_name(rig) do
    case rig["name"] do
      nil -> {:ok, nil}
      name when is_binary(name) -> {:ok, name}
      _ -> {:error, "rig.name must be a string"}
    end
  end

  defp validate_canvas(rig) do
    canvas = canvas(rig)

    cond do
      not is_map(canvas) ->
        {:error, "rig.canvas must be an object"}

      not positive_integer?(canvas["width"]) ->
        {:error, "rig.canvas.width must be a positive integer"}

      not positive_integer?(canvas["height"]) ->
        {:error, "rig.canvas.height must be a positive integer"}

      true ->
        {:ok, canvas}
    end
  end

  defp validate_bones(rig, allow_empty) do
    bones = bones(rig)

    cond do
      bones == [] and allow_empty ->
        validate_parents([])

      bones == [] ->
        {:error, "rig.bones must be a non-empty list"}

      true ->
        with :ok <- each_bone(bones), do: validate_parents(bones)
    end
  end

  defp each_bone(bones) do
    Enum.reduce_while(Enum.with_index(bones), :ok, fn {bone, index}, :ok ->
      case validate_bone(bone, index) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_bone(bone, index) when is_map(bone) do
    cond do
      not (is_binary(bone["id"]) and bone["id"] != "") ->
        {:error, "rig.bones[#{index}].id must be a non-empty string"}

      not is_map(bone["rest"]) ->
        {:error, "rig.bones[#{index}].rest is required"}

      not valid_point?(get_in(bone, ["rest", "head"])) ->
        {:error, "rig.bones[#{index}].rest.head must be [x, y]"}

      not valid_point?(get_in(bone, ["rest", "tail"])) ->
        {:error, "rig.bones[#{index}].rest.tail must be [x, y]"}

      not (is_number(bone["radius"] || @default_radius) and
               (bone["radius"] || @default_radius) > 0) ->
        {:error, "rig.bones[#{index}].radius must be a positive number"}

      (bone["falloff"] || "smooth") not in @falloffs ->
        {:error, "rig.bones[#{index}].falloff must be smooth, linear or hard"}

      true ->
        {:ok, bone}
    end
  end

  defp validate_bone(_bone, index), do: {:error, "rig.bones[#{index}] must be an object"}

  defp validate_parents(bones) do
    ids = MapSet.new(bones, & &1["id"])

    cond do
      MapSet.size(ids) != length(bones) ->
        {:error, "duplicate bone id"}

      true ->
        parents = Map.new(bones, &{&1["id"], &1["parent"]})

        cond do
          Enum.any?(parents, fn {_id, parent} ->
            parent != nil and not MapSet.member?(ids, parent)
          end) ->
            {:error, "bone parent references an unknown bone"}

          cyclic?(parents) ->
            {:error, "cycle detected in bone hierarchy"}

          true ->
            {:ok, bones}
        end
    end
  end

  defp cyclic?(parents) do
    Enum.any?(Map.keys(parents), fn id ->
      Enum.reduce_while(Stream.iterate(parents[id], &Map.get(parents, &1)), MapSet.new([id]), fn
        nil, _seen ->
          {:halt, false}

        current, seen ->
          if MapSet.member?(seen, current) do
            {:halt, true}
          else
            {:cont, MapSet.put(seen, current)}
          end
      end)
    end)
  end

  defp validate_keyframes(rig, bones) do
    ids = MapSet.new(bones, & &1["id"])

    Enum.reduce_while(keyframes(rig), {:ok, nil}, fn keyframe, acc ->
      case validate_keyframe(keyframe, ids) do
        :ok -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_keyframe(keyframe, ids) when is_map(keyframe) do
    frame = keyframe["frame"]
    pose = keyframe["pose"] || %{}

    cond do
      not (is_integer(frame) and frame >= 0) ->
        {:error, "rig.keyframes[].frame must be a non-negative integer"}

      not is_map(pose) ->
        {:error, "rig.keyframes[].pose must be an object"}

      true ->
        Enum.reduce_while(pose, :ok, fn {bone_id, local}, :ok ->
          cond do
            not MapSet.member?(ids, bone_id) ->
              {:halt, {:error, "keyframe references unknown bone #{inspect(bone_id)}"}}

            not is_map(local) ->
              {:halt, {:error, "pose for #{inspect(bone_id)} must be an object"}}

            not Enum.all?(["rot", "tx", "ty"], &is_number(local[&1] || 0.0)) ->
              {:halt, {:error, "pose for #{inspect(bone_id)} must be numeric"}}

            true ->
              {:cont, :ok}
          end
        end)
    end
  end

  defp validate_keyframe(_keyframe, _ids), do: {:error, "rig.keyframes[] must be an object"}

  defp validate_bind(rig) do
    bind = rig["bind"] || %{}

    cond do
      not is_map(bind) ->
        {:error, "rig.bind must be an object"}

      not (is_number(bind["power"] || @default_power) and (bind["power"] || @default_power) >= 0) ->
        {:error, "rig.bind.power must be >= 0"}

      not (is_number(bind["radius_scale"] || 1.0) and (bind["radius_scale"] || 1.0) > 0) ->
        {:error, "rig.bind.radius_scale must be > 0"}

      true ->
        {:ok, bind}
    end
  end

  defp validate_duration(rig) do
    duration = rig["duration"] || %{}

    cond do
      not is_map(duration) ->
        {:error, "rig.duration must be an object"}

      Map.has_key?(duration, "frames") and not positive_integer?(duration["frames"]) ->
        {:error, "rig.duration.frames must be a positive integer"}

      Map.has_key?(duration, "fps") and not (is_number(duration["fps"]) and duration["fps"] > 0) ->
        {:error, "rig.duration.fps must be > 0"}

      true ->
        {:ok, duration}
    end
  end

  defp validate_source(_rig, nil), do: {:ok, nil}

  defp validate_source(rig, project_dir) do
    case rig["source"] do
      nil ->
        {:ok, nil}

      %{"path" => path} when is_binary(path) ->
        case confine_to_project(path, project_dir) do
          {:ok, _} ->
            {:ok, nil}

          {:error, :escaping_path} ->
            {:error, "rig.source.path must stay within the project directory"}
        end

      source when is_map(source) ->
        {:ok, source}

      _ ->
        {:error, "rig.source must be an object"}
    end
  end

  @doc """
  Resolve `path` relative to `project_dir`, rejecting anything that escapes it.

  Rejects absolute paths, `..` traversal and symlinks whose target leaves the
  project directory. Returns `{:ok, absolute_path}` or `{:error, :escaping_path}`.
  """
  def confine_to_project(path, project_dir) when is_binary(path) and is_binary(project_dir) do
    root = Path.expand(project_dir)
    relative = path |> Path.expand(root) |> Path.relative_to(root)

    cond do
      relative == "." or Path.type(relative) == :absolute ->
        {:error, :escaping_path}

      match?([".." | _], Path.split(relative)) ->
        {:error, :escaping_path}

      true ->
        case Path.safe_relative(relative, root) do
          {:ok, safe} -> {:ok, Path.join(root, safe)}
          :error -> {:error, :escaping_path}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # bones
  # ---------------------------------------------------------------------------

  @doc "Default influence radius for a canvas - large enough that a fresh bone actually binds."
  def auto_radius(rig) do
    (max(width(rig), height(rig)) / 5.0)
    |> max(16.0)
    |> round3()
  end

  @doc "Add a bone; returns `{rig, bone_id}`."
  def add_bone(rig, head, tail, opts \\ []) do
    id = opts[:id] || next_bone_id(rig)
    radius = opts[:radius] || auto_radius(rig)
    parent = opts[:parent]

    bone = %{
      "id" => id,
      "name" => opts[:name] || "bone #{length(bones(rig)) + 1}",
      "parent" => parent,
      "rest" => %{"head" => point(head), "tail" => point(tail)},
      "radius" => radius,
      "falloff" => opts[:falloff] || "smooth"
    }

    {put_bones(rig, bones(rig) ++ [bone]), id}
  end

  @doc "Move a bone's head/tail. Either endpoint may be `nil` to keep it."
  def move_bone(rig, id, head, tail) do
    update_bone(rig, id, fn bone ->
      rest = bone["rest"]

      rest =
        rest
        |> then(fn r -> if head, do: Map.put(r, "head", point(head)), else: r end)
        |> then(fn r -> if tail, do: Map.put(r, "tail", point(tail)), else: r end)

      %{bone | "rest" => rest}
    end)
  end

  @doc "Translate a bone (head and tail) by `dx`, `dy`."
  def translate_bone(rig, id, dx, dy) do
    update_bone(rig, id, fn bone ->
      rest = bone["rest"]

      %{
        bone
        | "rest" => %{
            "head" => shift(rest["head"], dx, dy),
            "tail" => shift(rest["tail"], dx, dy)
          }
      }
    end)
  end

  @doc "Set a bone's parent (or `nil` to detach). Refuses cycles."
  def set_parent(rig, id, parent) do
    cond do
      id == parent ->
        {:error, "a bone cannot parent itself"}

      parent != nil and is_nil(bone(rig, parent)) ->
        {:error, "unknown parent #{inspect(parent)}"}

      parent != nil and descendant?(rig, parent, id) ->
        {:error, "that parent would create a cycle"}

      true ->
        {:ok, update_bone(rig, id, &Map.put(&1, "parent", parent))}
    end
  end

  @doc "Remove a bone and re-parent its children to its own parent."
  def delete_bone(rig, id) do
    case bone(rig, id) do
      nil ->
        rig

      removed ->
        parent = removed["parent"]

        new_bones =
          bones(rig)
          |> Enum.reject(&(&1["id"] == id))
          |> Enum.map(fn b -> if b["parent"] == id, do: Map.put(b, "parent", parent), else: b end)

        new_keyframes =
          keyframes(rig)
          |> Enum.map(fn kf ->
            pose = Map.delete(kf["pose"] || %{}, id)
            Map.put(kf, "pose", pose)
          end)

        rig
        |> put_bones(new_bones)
        |> Map.put("keyframes", new_keyframes)
    end
  end

  @doc "Set the per-bone influence radius (pixels)."
  def set_radius(rig, id, radius) when is_number(radius) and radius > 0 do
    update_bone(rig, id, &Map.put(&1, "radius", round3(radius)))
  end

  @doc "Set the per-bone falloff (`smooth` | `linear` | `hard`)."
  def set_falloff(rig, id, falloff) when falloff in @falloffs do
    update_bone(rig, id, &Map.put(&1, "falloff", falloff))
  end

  @doc "Set the global bind falloff exponent and radius scale."
  def set_bind(rig, opts) do
    bind = rig["bind"] || %{}

    bind =
      bind
      |> maybe_put("power", opts[:power], &round3/1)
      |> maybe_put("radius_scale", opts[:radius_scale], &round3/1)

    Map.put(rig, "bind", bind)
  end

  # ---------------------------------------------------------------------------
  # control mesh (bind pose)
  # ---------------------------------------------------------------------------

  @doc """
  Build the display control mesh over the canvas: `{vertices, triangles}`.

  `vertices` is a list of `[x, y]` image-space points, `triangles` a list of
  index triples. A coarser grid than the renderer's dense field is intentional:
  the mesh is the editor wireframe, the renderer always uses the dense weights.
  """
  def build_grid_mesh(rig, cell_size \\ nil) do
    width = width(rig)
    height = height(rig)

    cell_size =
      cell_size || max(8.0, max(width, height) / 40.0)

    cols = max(2, ceil(width / cell_size) + 1)
    rows = max(2, ceil(height / cell_size) + 1)

    xs = linspace(0.0, width - 1, cols)
    ys = linspace(0.0, height - 1, rows)

    vertices =
      for y <- ys, x <- xs, do: [round3(x), round3(y)]

    triangles =
      for row <- 0..(rows - 2), col <- 0..(cols - 2), reduce: [] do
        acc ->
          top_left = row * cols + col
          top_right = top_left + 1
          bottom_left = (row + 1) * cols + col
          bottom_right = bottom_left + 1

          acc ++ [[top_left, top_right, bottom_right], [top_left, bottom_right, bottom_left]]
      end

    {vertices, triangles}
  end

  @doc "Rebuild the control mesh for the current bones, including per-vertex weights."
  def auto_bind(rig) do
    {vertices, triangles} = build_grid_mesh(rig)
    weights = compute_vertex_weights(rig, vertices)

    mesh = %{
      "mode" => "grid",
      "vertices" => vertices,
      "triangles" => triangles,
      "weights" => weights
    }

    rig
    |> Map.put("mesh", mesh)
    |> Map.put("bind", Map.put(rig["bind"] || %{}, "mode", "auto"))
  end

  @doc """
  Per-vertex weights using the engine's distance/radius/falloff rule.

  Mirrors `core.deform.compute_vertex_weights`: each row is a per-bone
  normalised weight vector, with an explicit nearest-bone fallback.
  """
  def compute_vertex_weights(_rig, []), do: []

  def compute_vertex_weights(rig, vertices) do
    bones = bones(rig)

    if bones == [] do
      Enum.map(vertices, fn _ -> [] end)
    else
      do_compute_vertex_weights(rig, vertices, bones)
    end
  end

  defp do_compute_vertex_weights(rig, vertices, bones) do
    power = get_in(rig, ["bind", "power"]) || @default_power
    radius_scale = get_in(rig, ["bind", "radius_scale"]) || 1.0

    segments = Enum.map(bones, &segment/1)

    distances =
      for vertex <- vertices do
        [vx, vy] = ensure_point(vertex)

        Enum.map(segments, fn {ax, ay, bx, by} ->
          distance_to_segment(vx, vy, ax, ay, bx, by)
        end)
      end

    influence_rows =
      Enum.map(distances, fn distance_row ->
        Enum.zip(distance_row, bones)
        |> Enum.map(fn {distance, bone} ->
          radius = (bone["radius"] || @default_radius) * radius_scale
          exponent = falloff_power(bone["falloff"] || "smooth", power)
          base = clamp(1.0 - distance / max(radius, 1.0e-6), 0.0, 1.0)

          case exponent do
            exponent when exponent == 0.0 -> if base > 0.0, do: 1.0, else: 0.0
            exponent -> :math.pow(base, exponent)
          end
        end)
      end)

    Enum.zip(influence_rows, distances)
    |> Enum.map(fn {row, distance_row} ->
      total = Enum.sum(row)

      if total > 0.0 do
        Enum.map(row, &round6(&1 / max(total, 1.0e-8)))
      else
        nearest = nearest_index(distance_row)

        row
        |> Enum.with_index()
        |> Enum.map(fn {_w, i} -> if i == nearest, do: 1.0, else: 0.0 end)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # keyframes / bone evaluation
  # ---------------------------------------------------------------------------

  @doc """
  Insert or replace the keyframe at `frame` with `poses` (`%{bone_id => pose}`).

  Only the given bones are written; existing bones in the same keyframe keep
  their pose. Returns the updated rig.
  """
  def record_keyframe(rig, frame, poses) when is_integer(frame) and frame >= 0 do
    merged_pose =
      case Enum.find(keyframes(rig), &(&1["frame"] == frame)) do
        nil -> %{}
        existing -> existing["pose"] || %{}
      end
      |> Map.merge(Enum.into(poses, %{}, fn {id, pose} -> {id, normalize_pose(pose)} end))

    updated = %{"frame" => frame, "pose" => merged_pose}

    new_keyframes =
      (keyframes(rig) |> Enum.reject(&(&1["frame"] == frame))) ++ [updated]

    rig
    |> Map.put("keyframes", Enum.sort_by(new_keyframes, & &1["frame"]))
    |> reindex_pose_keys()
  end

  @doc "Remove the keyframe at `frame`."
  def delete_keyframe(rig, frame) do
    Map.put(rig, "keyframes", Enum.reject(keyframes(rig), &(&1["frame"] == frame)))
  end

  @doc """
  The interpolated local pose (`%{"rot" => _, "tx" => _, "ty" => _}`) for a single
  bone at `frame`.

  Mirrors `core.deform.interpolate_keyframes/2` (and `lbs.mjs` `interpolatePoses`):
  linear interpolation between the surrounding keyframes, clamped before the first
  and after the last, with a missing bone defaulting to the identity pose.
  """
  def interpolate_pose(rig, bone_id, frame) do
    case Enum.sort_by(keyframes(rig), & &1["frame"]) do
      [] ->
        %{"rot" => 0.0, "tx" => 0.0, "ty" => 0.0}

      keyframes ->
        first = hd(keyframes)
        last = List.last(keyframes)

        cond do
          frame <= first["frame"] ->
            bone_pose(first, bone_id)

          frame >= last["frame"] ->
            bone_pose(last, bone_id)

          true ->
            {left, right} = bracket(keyframes, frame)
            span = right["frame"] - left["frame"]
            t = if span <= 0, do: 0.0, else: (frame - left["frame"]) / span
            lp = bone_pose(left, bone_id)
            rp = bone_pose(right, bone_id)

            %{
              "rot" => lp["rot"] + (rp["rot"] - lp["rot"]) * t,
              "tx" => lp["tx"] + (rp["tx"] - lp["tx"]) * t,
              "ty" => lp["ty"] + (rp["ty"] - lp["ty"]) * t
            }
        end
    end
  end

  defp bracket(keyframes, frame) do
    keyframes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [left, right] -> left["frame"] <= frame and frame <= right["frame"] end)
    |> then(fn [left, right] -> {left, right} end)
  end

  defp bone_pose(keyframe, bone_id) do
    raw = (keyframe["pose"] || %{})[bone_id] || %{}

    %{
      "rot" => to_number(raw["rot"]),
      "tx" => to_number(raw["tx"]),
      "ty" => to_number(raw["ty"])
    }
  end

  # ---------------------------------------------------------------------------
  # geometry helpers
  # ---------------------------------------------------------------------------

  @doc "Distance from `(px, py)` to the segment `(ax, ay)-(bx, by)`."
  def distance_to_segment(px, py, ax, ay, bx, by) do
    vx = bx - ax
    vy = by - ay
    wx = px - ax
    wy = py - ay
    seg_len2 = vx * vx + vy * vy

    if seg_len2 <= 1.0e-12 do
      :math.sqrt(wx * wx + wy * wy)
    else
      t = clamp((wx * vx + wy * vy) / seg_len2, 0.0, 1.0)
      dx = wx - t * vx
      dy = wy - t * vy
      :math.sqrt(dx * dx + dy * dy)
    end
  end

  defp segment(bone) do
    [hx, hy] = ensure_point(bone["rest"]["head"])
    [tx, ty] = ensure_point(bone["rest"]["tail"])
    {to_number(hx), to_number(hy), to_number(tx), to_number(ty)}
  end

  def falloff_power("linear", _default), do: 1.0
  def falloff_power("hard", _default), do: 0.0
  def falloff_power(_smooth, default), do: to_number(default)

  # ---------------------------------------------------------------------------
  # small numeric/map helpers
  # ---------------------------------------------------------------------------

  defp next_bone_id(rig) do
    used = MapSet.new(bones(rig), & &1["id"])

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find(fn i -> not MapSet.member?(used, "b#{i}") end)
    |> then(&"b#{&1}")
  end

  defp update_bone(rig, id, fun) do
    Map.put(
      rig,
      "bones",
      Enum.map(bones(rig), fn b -> if b["id"] == id, do: fun.(b), else: b end)
    )
  end

  defp put_bones(rig, new_bones), do: Map.put(rig, "bones", new_bones)

  defp descendant?(rig, candidate, ancestor) do
    by_id = Map.new(bones(rig), &{&1["id"], &1})

    Stream.iterate(candidate, fn id -> by_id[id] && by_id[id]["parent"] end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.member?(ancestor)
  end

  # Keyframes always carry a full per-bone pose so the engine never has to guess;
  # normalising here also drops transient/bogus keys.
  defp reindex_pose_keys(rig) do
    ids = MapSet.new(bones(rig), & &1["id"])

    keyframes =
      Enum.map(keyframes(rig), fn kf ->
        pose =
          (kf["pose"] || %{})
          |> Enum.filter(fn {id, _} -> MapSet.member?(ids, id) end)
          |> Map.new(fn {id, pose} -> {id, normalize_pose(pose)} end)

        %{"frame" => kf["frame"], "pose" => pose}
      end)

    Map.put(rig, "keyframes", keyframes)
  end

  defp normalize_pose(pose) when is_map(pose) do
    %{
      "rot" => number(pose["rot"] || pose[:rot]),
      "tx" => number(pose["tx"] || pose[:tx]),
      "ty" => number(pose["ty"] || pose[:ty])
    }
  end

  defp normalize_pose(_), do: %{"rot" => 0.0, "tx" => 0.0, "ty" => 0.0}

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_), do: 0.0

  defp point({x, y}), do: [round3(x), round3(y)]
  defp point([x, y]), do: [round3(x), round3(y)]

  defp ensure_point({x, y}), do: [x, y]
  defp ensure_point([x, y]), do: [x, y]

  defp shift([x, y], dx, dy), do: [round3(to_number(x) + dx), round3(to_number(y) + dy)]
  defp shift({x, y}, dx, dy), do: shift([x, y], dx, dy)

  defp valid_point?([x, y]), do: is_number(x) and is_number(y)
  defp valid_point?(_), do: false

  defp nearest_index(list) do
    list
    |> Enum.with_index()
    |> Enum.min_by(fn {value, _index} -> value end)
    |> elem(1)
  end

  defp linspace(_first, _last, 1), do: [0.0]

  defp linspace(first, last, count) do
    step = (last - first) / (count - 1)
    Enum.map(0..(count - 1), fn i -> first + i * step end)
  end

  defp maybe_put(map, _key, nil, _fun), do: map
  defp maybe_put(map, key, value, fun), do: Map.put(map, key, fun.(value))

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp to_number(value) when is_integer(value), do: value * 1.0
  defp to_number(value) when is_float(value), do: value
  defp to_number(_), do: 0.0

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: trunc(value)
  defp to_integer(_), do: 0

  defp round3(value) when is_number(value), do: Float.round(value * 1.0, 3)
  defp round6(value) when is_number(value), do: Float.round(value * 1.0, 6)
end
