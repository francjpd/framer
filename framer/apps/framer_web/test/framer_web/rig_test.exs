defmodule FramerWeb.RigTest do
  use ExUnit.Case, async: true

  alias FramerWeb.Rig
  alias FramerWebWeb.Fixtures

  describe "new/3 and validate/2" do
    test "builds a valid, engine-shaped v1 document" do
      rig = Rig.new(640, 480, name: "Rig")

      assert rig["schema"] == "framer.rig"
      assert rig["version"] == 1
      assert rig["canvas"] == %{"width" => 640, "height" => 480}
      assert rig["bones"] == []
      assert rig["keyframes"] == []
      assert rig["playback"] == %{"loop" => true}

      # The editor may persist an empty rig (before the first bone), but the
      # strict engine contract requires at least one bone.
      assert {:ok, ^rig} = Rig.validate(rig, allow_empty_bones: true)
      assert {:error, message} = Rig.validate(rig)
      assert message =~ "non-empty"
    end

    test "rejects a foreign schema and version" do
      assert {:error, message} = Rig.validate(%{"schema" => "other", "version" => 1})
      assert message =~ "schema"

      rig = Rig.new(16, 16) |> Map.put("version", 2)
      assert {:error, message} = Rig.validate(rig, allow_empty_bones: true)
      assert message =~ "version"
    end

    test "rejects a cyclic bone hierarchy" do
      rig = Rig.new(64, 64)
      {rig, a} = Rig.add_bone(rig, [10, 10], [10, 30])
      {rig, b} = Rig.add_bone(rig, [10, 30], [10, 50], parent: a)

      cyclic =
        rig
        |> Map.put(
          "bones",
          Enum.map(Rig.bones(rig), fn bone ->
            if bone["id"] == a, do: Map.put(bone, "parent", b), else: bone
          end)
        )

      assert {:error, message} = Rig.validate(cyclic)
      assert message =~ "cycle"
    end

    test "rejects unknown parents and malformed bones" do
      rig = Rig.new(64, 64)
      {rig, a} = Rig.add_bone(rig, [10, 10], [10, 30])
      rig = Rig.set_parent(rig, a, "missing")
      assert {:error, _} = rig

      bad = %{Rig.new(64, 64) | "bones" => [%{"id" => "b0", "rest" => %{"head" => [1, 2]}}]}
      assert {:error, message} = Rig.validate(bad)
      assert message =~ "tail"
    end

    test "returns a validation error, not a crash, for non-object bind and duration" do
      {rig, _id} = Rig.add_bone(Rig.new(64, 64), [10, 10], [10, 30])

      assert {:error, message} = Rig.validate(%{rig | "bind" => []}, allow_empty_bones: true)
      assert message =~ "bind"

      assert {:error, message} = Rig.validate(%{rig | "duration" => []}, allow_empty_bones: true)
      assert message =~ "duration"
    end

    test "a partial duration fills each missing key from the defaults" do
      {rig, _id} = Rig.add_bone(Rig.new(64, 64), [10, 10], [10, 30])
      partial = %{rig | "duration" => %{"frames" => 10}}

      assert {:ok, _} = Rig.validate(partial, allow_empty_bones: true)
      assert Rig.frame_count(partial) == 10
      assert Rig.fps(partial) == 24

      only_fps = %{rig | "duration" => %{"fps" => 12}}
      assert Rig.frame_count(only_fps) == 48
      assert Rig.fps(only_fps) == 12
    end
  end

  describe "source confinement" do
    test "accepts a relative source path inside the project directory" do
      rig =
        Rig.new(64, 64, source_path: "assets/character.png")
        |> Rig.add_bone([10, 10], [10, 30])
        |> elem(0)

      assert {:ok, _} = Rig.validate(rig, allow_empty_bones: true, project_dir: "/tmp/project")
    end

    test "rejects absolute, escaping and traversing source paths" do
      {rig, _id} = Rig.add_bone(Rig.new(64, 64), [10, 10], [10, 30])

      for path <- [
            "/etc/passwd",
            "../../secret.png",
            "../secret.png"
          ] do
        escaping = put_in(rig, ["source", "path"], path)

        assert {:error, message} =
                 Rig.validate(escaping, allow_empty_bones: true, project_dir: "/tmp/project")

        assert message =~ "project directory"
      end
    end

    test "rejects a source symlink that points outside the project directory" do
      root = Path.join(System.tmp_dir!(), "framer_confine_#{System.unique_integer([:positive])}")
      project = Path.join(root, "project")
      File.mkdir_p!(project)
      secret = Path.join(root, "secret.png")
      File.write!(secret, "secret")
      link = Path.join(project, "escape.png")
      File.ln_s!(secret, link)

      on_exit(fn -> File.rm_rf(root) end)

      {rig, _id} = Rig.add_bone(Rig.new(64, 64), [10, 10], [10, 30])
      rig = put_in(rig, ["source", "path"], "escape.png")

      assert {:error, message} =
               Rig.validate(rig, allow_empty_bones: true, project_dir: project)

      assert message =~ "project directory"
    end
  end

  describe "bones" do
    test "add_bone assigns sequential ids and defaults" do
      rig = Rig.new(100, 100)
      {rig, first} = Rig.add_bone(rig, [0, 0], [0, 10])
      {rig, second} = Rig.add_bone(rig, [0, 10], [0, 20], parent: first)

      assert first == "b0"
      assert second == "b1"

      second_bone = Rig.bone(rig, second)
      assert second_bone["parent"] == first
      assert second_bone["radius"] > 0
      assert second_bone["falloff"] == "smooth"
    end

    test "move and translate update the rest segment" do
      {rig, id} = Rig.add_bone(Rig.new(100, 100), [10, 10], [10, 40])
      rig = Rig.move_bone(rig, id, [20, 20], nil)
      assert Rig.bone(rig, id)["rest"]["head"] == [20.0, 20.0]
      assert Rig.bone(rig, id)["rest"]["tail"] == [10.0, 40.0]

      rig = Rig.translate_bone(rig, id, 5, -5)
      assert Rig.bone(rig, id)["rest"]["head"] == [25.0, 15.0]
      assert Rig.bone(rig, id)["rest"]["tail"] == [15.0, 35.0]
    end

    test "delete_bone re-parents children and drops its keyframe poses" do
      rig = Rig.new(100, 100)
      {rig, a} = Rig.add_bone(rig, [0, 0], [0, 10])
      {rig, b} = Rig.add_bone(rig, [0, 10], [0, 20], parent: a)
      {rig, c} = Rig.add_bone(rig, [0, 20], [0, 30], parent: b)

      rig = Rig.record_keyframe(rig, 0, %{a => %{rot: 0.1}, b => %{rot: 0.2}, c => %{rot: 0.3}})
      rig = Rig.delete_bone(rig, b)

      assert Rig.bone(rig, b) == nil
      assert Rig.bone(rig, c)["parent"] == a
      refute Map.has_key?(hd(Rig.keyframes(rig))["pose"], b)
    end

    test "set_parent refuses self and cycles" do
      rig = Rig.new(100, 100)
      {rig, a} = Rig.add_bone(rig, [0, 0], [0, 10])
      {rig, b} = Rig.add_bone(rig, [0, 10], [0, 20], parent: a)

      assert {:error, _} = Rig.set_parent(rig, a, a)
      assert {:error, message} = Rig.set_parent(rig, a, b)
      assert message =~ "cycle"
      assert {:ok, detached} = Rig.set_parent(rig, b, nil)
      assert Rig.bone(detached, b)["parent"] == nil
    end

    test "set_radius, set_falloff and set_bind update the document" do
      {rig, id} = Rig.add_bone(Rig.new(200, 200), [50, 50], [50, 150])

      rig = Rig.set_radius(rig, id, 42.25)
      assert Rig.bone(rig, id)["radius"] == 42.25

      rig = Rig.set_falloff(rig, id, "hard")
      assert Rig.bone(rig, id)["falloff"] == "hard"

      rig = Rig.set_bind(rig, power: 3.5, radius_scale: 1.5)
      assert rig["bind"]["power"] == 3.5
      assert rig["bind"]["radius_scale"] == 1.5
    end
  end

  describe "control mesh and weights" do
    test "build_grid_mesh covers the canvas and triangulates it" do
      rig = Rig.new(80, 40)
      {vertices, triangles} = Rig.build_grid_mesh(rig, 20)

      assert length(vertices) > 0
      assert Enum.all?(vertices, fn [x, y] -> x >= 0 and x <= 79 and y >= 0 and y <= 39 end)

      unique_x = vertices |> Enum.map(&hd/1) |> Enum.uniq() |> length()
      unique_y = vertices |> Enum.map(&List.last/1) |> Enum.uniq() |> length()
      assert unique_x * unique_y == length(vertices)
      assert length(triangles) == 2 * (unique_x - 1) * (unique_y - 1)
      assert Enum.all?(triangles, fn [a, b, c] -> a >= 0 and b >= 0 and c >= 0 end)
    end

    test "auto_bind stores mesh vertices, triangles and normalised weights" do
      {rig, _id} = Rig.add_bone(Rig.new(80, 80), [40, 40], [40, 10], radius: 40)
      rig = Rig.auto_bind(rig)

      mesh = rig["mesh"]
      assert mesh["mode"] == "grid"
      assert length(mesh["vertices"]) == length(mesh["weights"])
      refute mesh["triangles"] == []

      for row <- mesh["weights"] do
        assert_in_delta Enum.sum(row), 1.0, 1.0e-6
      end
    end

    test "compute_vertex_weights falls back to the nearest bone" do
      rig = Rig.new(40, 40)
      {rig, a} = Rig.add_bone(rig, [5, 5], [5, 15], radius: 1)
      {rig, b} = Rig.add_bone(rig, [35, 35], [35, 25], radius: 1)

      # A vertex far from every radius must still sum to 1.
      [row] = Rig.compute_vertex_weights(rig, [[20, 20]])
      assert_in_delta Enum.sum(row), 1.0, 1.0e-6
      assert Enum.max(row) == 1.0

      # Near b's head, b dominates.
      [near_b] = Rig.compute_vertex_weights(rig, [[35, 35]])
      b_index = Enum.find_index(Rig.bones(rig), &(&1["id"] == b))
      a_index = Enum.find_index(Rig.bones(rig), &(&1["id"] == a))
      assert Enum.at(near_b, b_index) >= Enum.at(near_b, a_index)
    end

    test "compute_vertex_weights handles a rig with no bones" do
      rig = Rig.new(10, 10)
      assert Rig.compute_vertex_weights(rig, [[1, 1], [2, 2]]) == [[], []]
    end
  end

  describe "keyframes and evaluation" do
    test "record_keyframe merges, replaces and sorts" do
      {rig, a} = Rig.add_bone(Rig.new(100, 100), [50, 90], [50, 10])
      {rig, b} = Rig.add_bone(rig, [50, 10], [90, 10], parent: a)

      rig = Rig.record_keyframe(rig, 10, %{a => %{rot: 0.5}})
      rig = Rig.record_keyframe(rig, 0, %{a => %{rot: 0.0}, b => %{rot: 0.0}})
      rig = Rig.record_keyframe(rig, 10, %{b => %{rot: 0.25}})

      assert Enum.map(Rig.keyframes(rig), & &1["frame"]) == [0, 10]

      merged = Enum.find(Rig.keyframes(rig), &(&1["frame"] == 10))
      assert merged["pose"][a] == %{"rot" => 0.5, "tx" => 0.0, "ty" => 0.0}
      assert merged["pose"][b]["rot"] == 0.25
    end

    test "delete_keyframe removes it" do
      {rig, a} = Rig.add_bone(Rig.new(100, 100), [50, 90], [50, 10])
      rig = Rig.record_keyframe(rig, 5, %{a => %{rot: 0.4}})
      assert Rig.delete_keyframe(rig, 5)["keyframes"] == []
    end

    test "interpolate_pose clamps, interpolates and defaults missing bones" do
      {rig, a} = Rig.add_bone(Rig.new(100, 100), [50, 90], [50, 10])
      rig =
        rig
        |> Rig.record_keyframe(0, %{a => %{rot: 0.0, tx: 0.0, ty: 0.0}})
        |> Rig.record_keyframe(10, %{a => %{rot: 1.0, tx: 10.0, ty: 20.0}})

      assert Rig.interpolate_pose(rig, a, -5) == %{"rot" => 0.0, "tx" => 0.0, "ty" => 0.0}
      assert Rig.interpolate_pose(rig, a, 20) == %{"rot" => 1.0, "tx" => 10.0, "ty" => 20.0}

      mid = Rig.interpolate_pose(rig, a, 5)
      assert_in_delta mid["rot"], 0.5, 1.0e-9
      assert_in_delta mid["tx"], 5.0, 1.0e-9
      assert_in_delta mid["ty"], 10.0, 1.0e-9

      empty = Rig.new(100, 100) |> Map.put("bones", [%{"id" => "b0"}])
      assert Rig.interpolate_pose(empty, "b0", 0) == %{"rot" => 0.0, "tx" => 0.0, "ty" => 0.0}
    end
  end

  describe "geometry helpers" do
    test "distance_to_segment handles the perpendicular, clamped and degenerate cases" do
      assert_in_delta Rig.distance_to_segment(5, 5, 0, 0, 10, 0), 5.0, 1.0e-9
      assert_in_delta Rig.distance_to_segment(-5, 0, 0, 0, 10, 0), 5.0, 1.0e-9
      assert_in_delta Rig.distance_to_segment(3, 4, 0, 0, 0, 0), 5.0, 1.0e-9
    end

    test "falloff_power maps the named falloffs" do
      assert Rig.falloff_power("linear", 2.0) == 1.0
      assert Rig.falloff_power("hard", 2.0) == 0.0
      assert Rig.falloff_power("smooth", 2.5) == 2.5
    end
  end

  describe "fixtures" do
    test "the fixture PNG is decodable by the image header reader" do
      binary = Fixtures.png(9, 4)
      assert {:ok, %{width: 9, height: 4, format: :png}} = FramerWeb.ImageInfo.read(binary)
    end
  end
end
