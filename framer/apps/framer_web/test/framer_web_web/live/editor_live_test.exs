defmodule FramerWebWeb.EditorLiveTest do
  use FramerWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  setup_all do
    original = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_editor_#{System.unique_integer([:positive])}")
    Application.put_env(:framer_web, :projects_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:framer_web, :projects_dir, original)
    end)

    :ok
  end

  # Save a rig under a distinct display name so list-based tests can target it.
  defp saved_rig(name, size \\ 32) do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(size) |> Map.put("name", name))
    rig
  end

  test "renders the three-pane shell and the upload control", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor")

    assert html =~ "Framer Editor"
    assert has_element?(view, "#editor-shell")
    assert has_element?(view, "#upload-form")
    assert has_element?(view, "button", "Bones")
    assert has_element?(view, "button", "Pose")
    assert has_element?(view, "button", "Load image")
    assert has_element?(view, "button", "Auto-bind mesh")
  end

  test "bone property and bind controls live inside a form so their events reach the server", %{
    conn: conn
  } do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "select_bone", %{"id" => "b0"})

    assert has_element?(view, "#bone-properties-form input[type='text'][name='name']")
    assert has_element?(view, "#bone-properties-form input[type='range'][name='radius']")
    assert has_element?(view, "#bone-properties-form select[name='falloff']")
    assert has_element?(view, "#bone-properties-form select[name='parent']")
    assert has_element?(view, "#bind-form input[type='range'][name='power']")
    assert has_element?(view, "#bind-form input[type='range'][name='radius_scale']")
  end

  test "loads a saved rig into the viewport and timeline", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(48))

    {:ok, view, html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    assert html =~ "root"
    assert has_element?(view, "#viewport")
    assert has_element?(view, "#timeline-track")
    assert has_element?(view, "#viewport[data-source-url='/api/rigs/#{rig["id"]}/source']")
    assert has_element?(view, "#viewport[data-tool='bones']")
  end

  test "switching tool updates the viewport", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "select_tool", %{"tool" => "pose"})
    assert has_element?(view, "#viewport[data-tool='pose']")
  end

  test "viewport zoom controls render with a rig and forward to the hook without touching the rig",
       %{
         conn: conn
       } do
    # No rig: the zoom controls are hidden (the viewport hook, which owns zoom,
    # only exists once a still is loaded).
    {:ok, view, _html} = live(conn, ~p"/editor")
    refute has_element?(view, "button[phx-click=\"zoom\"]")

    {:ok, rig} = RigStore.save(Fixtures.simple_rig(48))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    assert has_element?(view, "button[phx-click=\"zoom\"][phx-value-action=\"in\"]")
    assert has_element?(view, "button[phx-click=\"zoom\"][phx-value-action=\"out\"]")
    assert has_element?(view, "button[phx-click=\"zoom\"][phx-value-action=\"fit\"]")

    # The zoom events are a pure view transform forwarded to the hook: they must
    # not mutate the rig document.
    render_hook(view, "zoom", %{"action" => "in"})
    render_hook(view, "zoom", %{"action" => "out"})
    render_hook(view, "zoom", %{"action" => "fit"})
    # An unknown action is ignored, not an error.
    render_hook(view, "zoom", %{"action" => "wat"})

    {:ok, loaded} = RigStore.load(rig["id"])
    assert loaded["bones"] == rig["bones"]
  end

  test "creating, binding and deleting bones round-trips through the store", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "bone_created", %{"head" => [10, 50], "tail" => [40, 50], "parent" => "b0"})
    {:ok, loaded} = RigStore.load(id)
    assert length(FramerWeb.Rig.bones(loaded)) == 2
    assert Enum.at(FramerWeb.Rig.bones(loaded), 1)["parent"] == "b0"

    render_click(view, "auto_bind")
    {:ok, bound} = RigStore.load(id)
    refute bound["mesh"]["vertices"] == []

    render_hook(view, "bone_deleted", %{"id" => "b0"})
    {:ok, after_delete} = RigStore.load(id)
    assert length(FramerWeb.Rig.bones(after_delete)) == 1
  end

  test "renaming a bone updates the editor and persists it under the same id", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "select_bone", %{"id" => "b0"})
    assert has_element?(view, "#bone-properties-form input[name='name']")

    # Record a pose first so we can prove the keyframe map still keys by bone id.
    render_hook(view, "pose_changed", %{
      "pose" => %{"b0" => %{"rot" => 0.4, "tx" => 0, "ty" => 0}}
    })

    render_hook(view, "record_keyframe", %{})
    render_hook(view, "set_bone_name", %{"id" => "b0", "name" => "tentacle 1"})

    assert render(view) =~ "tentacle 1"

    {:ok, loaded} = RigStore.load(id)
    renamed = FramerWeb.Rig.bone(loaded, "b0")
    assert renamed["name"] == "tentacle 1"
    assert renamed["id"] == "b0"

    assert Enum.any?(FramerWeb.Rig.keyframes(loaded), fn keyframe ->
             get_in(keyframe, ["pose", "b0"]) != nil
           end)
  end

  test "renaming via the form change event (no id param) persists under the selected bone", %{
    conn: conn
  } do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "select_bone", %{"id" => "b0"})

    # The browser sends only the changed field; the id is never in the params.
    render_change(view, "set_bone_name", %{"name" => "tentacle 1"})

    assert render(view) =~ "tentacle 1"

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b0")["name"] == "tentacle 1"
    assert FramerWeb.Rig.bone(loaded, "b0")["id"] == "b0"
  end

  test "an empty or blank bone name is rejected and leaves the document unchanged", %{
    conn: conn
  } do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(48))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "set_bone_name", %{"id" => "b0", "name" => "   "})
    assert render(view) =~ "Bone name must be a non-empty string"

    render_hook(view, "set_bone_name", %{"id" => "b0", "name" => ""})
    assert render(view) =~ "Bone name must be a non-empty string"

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b0")["name"] == "root"
  end

  test "the move handle translates a bone (bone_translated)", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    # The move handle's drag path pushes bone_translated with a delta.
    render_hook(view, "bone_translated", %{"id" => "b0", "dx" => 5, "dy" => -3})

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b0")["rest"]["head"] == [37.0, 29.0]
    assert FramerWeb.Rig.bone(loaded, "b0")["rest"]["tail"] == [37.0, 13.0]
  end

  test "the rotate handle moves the tail in the bones tool (bone_moved)", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    # The rotate handle's bones-tool drag path pushes bone_moved with a new tail.
    render_hook(view, "bone_moved", %{"id" => "b0", "head" => [32, 32], "tail" => [48, 8]})

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b0")["rest"]["head"] == [32.0, 32.0]
    assert FramerWeb.Rig.bone(loaded, "b0")["rest"]["tail"] == [48.0, 8.0]
  end

  test "the link handle drag parents the dragged bone (bone_linked)", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "bone_created", %{"head" => [8, 40], "tail" => [24, 40]})

    # The viewport's link-dot drag pushes bone_linked with the dragged bone's
    # id and the bone it was dropped on - the same set_parent the dropdown
    # drives, so the drag is a shortcut for the precise control.
    render_hook(view, "bone_linked", %{"id" => "b1", "parent" => "b0"})

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b1")["parent"] == "b0"
    assert FramerWeb.Rig.bone(loaded, "b0")["parent"] == nil
  end

  test "a link drag that would cycle is refused exactly like the dropdown", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "bone_created", %{"head" => [8, 40], "tail" => [24, 40], "parent" => "b0"})

    # b0 already parents b1; linking b0 onto b1 would cycle, and so would a bone
    # linking to itself. Both are refused and leave the document untouched.
    render_hook(view, "bone_linked", %{"id" => "b0", "parent" => "b1"})
    assert render(view) =~ "cycle"

    render_hook(view, "bone_linked", %{"id" => "b0", "parent" => "b0"})
    assert render(view) =~ "itself"

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b0")["parent"] == nil
    assert FramerWeb.Rig.bone(loaded, "b1")["parent"] == "b0"
  end

  test "an unknown or missing link target is refused without crashing", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "bone_linked", %{"id" => "b0", "parent" => "nope"})
    assert render(view) =~ "unknown parent"

    render_hook(view, "bone_linked", %{"parent" => "b0"})
    assert render(view)

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.bone(loaded, "b0")["parent"] == nil
  end

  test "recording a pose as a keyframe persists it", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "set_playhead", %{"frame" => 6})
    assert has_element?(view, "#viewport[data-frame='6']")

    render_hook(view, "pose_changed", %{
      "pose" => %{"b0" => %{"rot" => 0.5, "tx" => 12, "ty" => -3}}
    })

    render_hook(view, "record_keyframe", %{})

    {:ok, loaded} = RigStore.load(id)
    keyframe = Enum.find(FramerWeb.Rig.keyframes(loaded), &(&1["frame"] == 6))
    assert keyframe["pose"]["b0"]["rot"] == 0.5
    assert keyframe["pose"]["b0"]["tx"] == 12.0
  end

  test "recording with nothing posed shows a hint and persists no keyframe", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    html = render_hook(view, "record_keyframe", %{})

    assert html =~ "Nothing to record"

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.keyframes(loaded) == []
  end

  test "stepping away from an unrecorded pose hints instead of discarding it silently", %{
    conn: conn
  } do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "pose_changed", %{
      "pose" => %{"b0" => %{"rot" => 0.5, "tx" => 12, "ty" => -3}}
    })

    render_hook(view, "step_frame", %{"delta" => 1})

    assert render(view) =~ "Pose not recorded"

    {:ok, loaded} = RigStore.load(id)
    assert FramerWeb.Rig.keyframes(loaded) == []
  end

  test "a failed merge shows an error and offers no Download link", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    payload = %{
      job_id: "job-1",
      status: :failed,
      output: "/projects/#{id}/output.webm",
      result: {:error, "FFmpeg merge failed"},
      error: "FFmpeg merge failed"
    }

    Phoenix.PubSub.broadcast(FramerWeb.PubSub, FramerWeb.Renderer.topic(id), {:export, payload})

    assert render(view) =~ "FFmpeg merge failed"
    refute has_element?(view, "a[download]")
  end

  test "invalid radius and falloff values are ignored without crashing", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(48))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    before = RigStore.load(id)

    render_hook(view, "set_radius", %{"id" => "b0", "radius" => ""})
    render_hook(view, "set_radius", %{"id" => "b0", "radius" => "not-a-number"})
    render_hook(view, "set_falloff", %{"id" => "b0", "falloff" => "bogus"})

    assert render(view)
    assert RigStore.load(id) == before
  end

  test "uploading a still creates a project and opens it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/editor")

    upload =
      file_input(view, "#upload-form", :source, [
        %{name: "still.png", content: Fixtures.png(20, 12), type: "image/png"}
      ])

    render_upload(upload, "still.png")

    html = view |> form("#upload-form") |> render_submit()

    assert html =~ "still"
    assert has_element?(view, "#viewport")
    assert has_element?(view, "#viewport[data-source-url]")
  end

  test "viewport toggles, transport stepping and graph channel update the shell", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(48))
    {:ok, view, html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    assert html =~ "Record keyframe"
    assert has_element?(view, "#viewport[data-mesh='true']")

    render_click(view, "toggle_mesh")
    assert has_element?(view, "#viewport[data-mesh='false']")

    render_click(view, "toggle_labels")
    assert has_element?(view, "#viewport[data-labels='true']")

    render_hook(view, "step_frame", %{"delta" => 3})
    assert has_element?(view, "#viewport[data-frame='3']")

    render_hook(view, "step_frame", %{"delta" => -100})
    assert has_element?(view, "#viewport[data-frame='0']")

    render_hook(view, "set_graph_channel", %{"channel" => "tx"})
    assert has_element?(view, "#timeline-track")
    assert render(view) =~ "tx"
  end

  test "renders a value and velocity graph for the selected bone", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "set_playhead", %{"frame" => 8})

    render_hook(view, "pose_changed", %{
      "pose" => %{"b0" => %{"rot" => 0.4, "tx" => 4, "ty" => 0}}
    })

    render_hook(view, "record_keyframe", %{})

    html = render(view)
    assert html =~ "polyline"
    assert html =~ "stroke-dasharray"
  end

  test "hierarchy nests child bones under their parent", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "bone_created", %{"head" => [10, 10], "tail" => [20, 10], "parent" => "b0"})

    assert render(view) =~ "└"
  end

  test "invalid radius or falloff input shows an error instead of crashing", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "set_radius", %{"id" => "b0", "radius" => "not-a-number"})
    assert render(view) =~ "Radius must be a positive number"

    render_hook(view, "set_falloff", %{"id" => "b0", "falloff" => "bogus"})
    assert render(view) =~ "Unknown falloff"
  end

  # --- workflow step guide ---------------------------------------------------

  test "fresh editor shows the five-step guide with step 1 current", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor")

    assert has_element?(view, "#step-guide")
    assert has_element?(view, "#step-guide [data-step='1'][data-current='true']")
    assert has_element?(view, "#step-guide [data-step='1'][data-done='false']")

    for step <- 2..5 do
      assert has_element?(view, "#step-guide [data-step='#{step}']")
      refute has_element?(view, "#step-guide [data-step='#{step}'][data-current='true']")
      refute has_element?(view, "#step-guide [data-step='#{step}'][data-done='true']")
    end

    assert html =~ "Load a still image"
    refute has_element?(view, "#viewport-hint")
  end

  test "a zero-bone rig shows step 2 current with the draw-a-bone hint", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.zero_bone_rig(64))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    assert has_element?(view, "#step-guide [data-step='2'][data-current='true']")
    assert has_element?(view, "#step-guide [data-step='1'][data-done='true']")
    refute has_element?(view, "#step-guide [data-step='2'][data-done='true']")
    refute has_element?(view, "#step-guide [data-step='3'][data-done='true']")

    assert has_element?(view, "#viewport-hint", "draw a bone")
  end

  test "bones that were never bound show step 3 with the Auto-bind hint", %{conn: conn} do
    rig = FramerWeb.Rig.new(64, 64, name: "Unbound fixture")
    {rig, _id} = FramerWeb.Rig.add_bone(rig, [16, 32], [48, 32])
    {:ok, saved} = RigStore.save(rig)
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{saved["id"]}")

    assert has_element?(view, "#step-guide [data-step='3'][data-current='true']")
    assert has_element?(view, "#step-guide [data-step='2'][data-done='true']")
    refute has_element?(view, "#step-guide [data-step='3'][data-done='true']")

    assert has_element?(view, "#viewport-hint", "Auto-bind mesh")
  end

  test "a bound rig without keyframes shows step 4 with the pose-and-record hint", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    assert has_element?(view, "#step-guide [data-step='4'][data-current='true']")
    assert has_element?(view, "#step-guide [data-step='3'][data-done='true']")
    refute has_element?(view, "#step-guide [data-step='4'][data-done='true']")

    assert has_element?(view, "#viewport-hint", "Record keyframe")
  end

  test "posing and recording a keyframe advances the guide to step 5", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "pose_changed", %{
      "pose" => %{"b0" => %{"rot" => 0.4, "tx" => 2, "ty" => 0}}
    })

    render_hook(view, "record_keyframe", %{})

    assert has_element?(view, "#step-guide [data-step='5'][data-current='true']")

    for step <- 1..4 do
      assert has_element?(view, "#step-guide [data-step='#{step}'][data-done='true']")
    end

    refute has_element?(view, "#step-guide [data-step='5'][data-done='true']")
    refute has_element?(view, "#viewport-hint")
  end

  test "re-binding after posing keeps keyframes, stays on step 5, and gates nothing", %{
    conn: conn
  } do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    render_hook(view, "pose_changed", %{
      "pose" => %{"b0" => %{"rot" => 0.7, "tx" => 5, "ty" => 1}}
    })

    render_hook(view, "record_keyframe", %{})
    assert has_element?(view, "#step-guide [data-step='5'][data-current='true']")

    render_click(view, "auto_bind")

    {:ok, rebound} = RigStore.load(id)
    assert length(FramerWeb.Rig.keyframes(rebound)) == 1

    assert has_element?(view, "#step-guide [data-step='5'][data-current='true']")

    for step <- 1..4 do
      assert has_element?(view, "#step-guide [data-step='#{step}'][data-done='true']")
    end

    for selector <- [
          "#palette button[phx-click='select_tool'][phx-value-tool='bones']",
          "#palette button[phx-click='select_tool'][phx-value-tool='pose']",
          "#palette button[phx-click='auto_bind']",
          "button[phx-click='record_keyframe']",
          "#render-frame-btn",
          "#export-form button[type='submit']"
        ] do
      assert has_element?(view, selector)
      refute has_element?(view, selector <> "[disabled]")
    end
  end

  test "deleting the last bone walks the guide back to step 2", %{conn: conn} do
    {:ok, rig} = RigStore.save(Fixtures.simple_rig(64))
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

    render_hook(view, "bone_deleted", %{"id" => "b0"})

    assert has_element?(view, "#step-guide [data-step='2'][data-current='true']")
    assert has_element?(view, "#step-guide [data-step='1'][data-done='true']")
    refute has_element?(view, "#step-guide [data-step='2'][data-done='true']")
  end

  # --- removing saved rigs ---------------------------------------------------

  test "removing a rig deletes its directory and drops it from the list", %{conn: conn} do
    kept = saved_rig("Keep me")
    doomed = saved_rig("Remove me")
    {:ok, view, _html} = live(conn, ~p"/editor")

    assert has_element?(view, "button[phx-value-id='#{kept["id"]}']")
    assert has_element?(view, "button[phx-value-id='#{doomed["id"]}']")

    # The remove control only reveals an inline confirm; it deletes nothing yet.
    render_click(view, "request_delete_project", %{"id" => doomed["id"]})

    assert has_element?(
             view,
             "button[phx-click='delete_project'][phx-value-id='#{doomed["id"]}']"
           )

    assert File.exists?(RigStore.project_dir(doomed["id"]))

    render_click(view, "delete_project", %{"id" => doomed["id"]})

    refute File.exists?(RigStore.project_dir(doomed["id"]))
    assert RigStore.load(doomed["id"]) == {:error, :enoent}
    refute has_element?(view, "button[phx-value-id='#{doomed["id"]}']")
    assert has_element?(view, "button[phx-value-id='#{kept["id"]}']")
    assert render(view) =~ "Removed Remove me"
  end

  test "cancelling the remove confirm deletes nothing", %{conn: conn} do
    rig = saved_rig("Keep me")
    {:ok, view, _html} = live(conn, ~p"/editor")

    render_click(view, "request_delete_project", %{"id" => rig["id"]})
    render_click(view, "cancel_delete_project", %{})

    refute has_element?(view, "button[phx-click='cancel_delete_project']")
    assert File.exists?(RigStore.project_dir(rig["id"]))
    assert {:ok, _loaded} = RigStore.load(rig["id"])
    assert has_element?(view, "button[phx-value-id='#{rig["id"]}']")
  end

  test "removing the open rig returns the editor to its empty state", %{conn: conn} do
    rig = saved_rig("Open me")
    id = rig["id"]
    {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

    assert has_element?(view, "#viewport")

    render_click(view, "request_delete_project", %{"id" => id})
    render_click(view, "delete_project", %{"id" => id})

    refute File.exists?(RigStore.project_dir(id))
    refute has_element?(view, "#viewport")
    assert has_element?(view, "#palette")
    assert render(view) =~ "Load a still image to start rigging."
    refute has_element?(view, "button[phx-value-id='#{id}']")
  end

  describe "the layer split" do
    test "offers the extraction control and explains the single-picture default", %{conn: conn} do
      rig = saved_rig("Layers off")
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      assert has_element?(view, "#toggle-background-layer", "Extract the character")
      # HEEx escapes the apostrophe to an entity, so the assertion window is the
      # apostrophe-free part of the sentence.
      assert render(view) =~ "reach also moves the background. Extract the character to"
      assert render(view) =~ "give it its own layer"
      refute has_element?(view, "#layer-tolerance-form")
      refute has_element?(view, "#viewport[data-character-url]")
      refute has_element?(view, "#viewport[data-background-url]")
    end

    test "asks for a rig first when none is loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor")

      render_click(view, "toggle_background_layer", %{})
      assert render(view) =~ "Load a rig first"
    end

    test "extracting the character persists the layered state and points the viewport at it", %{
      conn: conn
    } do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "s.png")
      _bones = Fixtures.simple_rig(32) |> Map.put("id", rig["id"]) |> then(&RigStore.save/1)
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.split?(saved)
      assert get_in(saved, ["layers", "tolerance"]) == 30
      assert get_in(saved, ["layers", "soft_edges"]) == 0
      assert get_in(saved, ["layers", "edge_cleanup"]) == 0
      assert FramerWeb.Rig.character_layer(saved) == FramerWeb.Rig.layer_filename()
      assert File.exists?(RigStore.character_layer_path(rig["id"]))

      # The engine materialises the opaque plate beside the cut-out, and the
      # preview points at both layers so it composites what the export renders.
      assert File.exists?(RigStore.plate_path(rig["id"]))

      assert has_element?(
               view,
               "#viewport[data-character-url='/api/rigs/#{rig["id"]}/character']"
             )

      assert has_element?(
               view,
               "#viewport[data-background-url='/api/rigs/#{rig["id"]}/background']"
             )

      assert has_element?(view, "span.badge", "layered")
      assert has_element?(view, "#toggle-background-layer", "Remove the character layer")
      assert render(view) =~ "the background now stays put"
    end

    test "turning the split off keeps the layers so undo can restore them", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "s.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})
      assert File.exists?(RigStore.character_layer_path(rig["id"]))

      render_click(view, "toggle_background_layer", %{})

      {:ok, saved} = RigStore.load(rig["id"])
      refute FramerWeb.Rig.split?(saved)
      refute Map.has_key?(saved, "layers")

      # The materialised layers stay on disk: undo restores the split document
      # pushed just before the toggle, and it must not point at a missing asset.
      assert File.exists?(RigStore.character_layer_path(rig["id"]))
      assert File.exists?(RigStore.plate_path(rig["id"]))

      assert has_element?(view, "#toggle-background-layer", "Extract the character")
      refute has_element?(view, "#viewport[data-character-url]")
      refute has_element?(view, "#viewport[data-background-url]")

      render_click(view, "undo", %{})

      {:ok, restored} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.split?(restored)
      assert File.exists?(RigStore.character_layer_path(rig["id"]))

      assert has_element?(
               view,
               "#viewport[data-character-url='/api/rigs/#{rig["id"]}/character']"
             )
    end

    test "changing the tolerance re-extracts with the new setting", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "s.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      # Split first so the cut-out is already materialised; moving the slider
      # must then re-key the existing layer rather than extract a fresh one.
      render_click(view, "toggle_background_layer", %{})
      assert File.exists?(RigStore.character_layer_path(rig["id"]))
      assert File.exists?(RigStore.plate_path(rig["id"]))

      render_change(view, "set_layer_tolerance", %{"tolerance" => "65"})

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.split?(saved)
      assert get_in(saved, ["layers", "tolerance"]) == 65
      assert has_element?(view, "#layer-tolerance-form input[value='65']")
      refute render(view) =~ "layer_not_materialised"

      # Both layers were re-materialised with the new key, so the preview picks
      # them up again through the same URLs.
      assert File.exists?(RigStore.character_layer_path(rig["id"]))
      assert File.exists?(RigStore.plate_path(rig["id"]))
    end

    test "a non-positive tolerance is rejected without touching the document", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "s.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_change(view, "set_layer_tolerance", %{"tolerance" => "0"})

      {:ok, saved} = RigStore.load(rig["id"])
      refute FramerWeb.Rig.split?(saved)
      assert render(view) =~ "Tolerance must be a positive number"
    end

    test "undo restores the unsplit document", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "s.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})
      assert FramerWeb.Rig.split?(elem(RigStore.load(rig["id"]), 1))

      render_click(view, "undo", %{})

      {:ok, restored} = RigStore.load(rig["id"])
      refute FramerWeb.Rig.split?(restored)
      refute has_element?(view, "#viewport[data-character-url]")
    end

    test "set_layer_tolerance with no rig returns error and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor")

      assert render_change(view, "set_layer_tolerance", %{"tolerance" => "40"}) =~
               "Load a rig first"
    end

    test "changing tolerance on a split rig preserves declared layer settings", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "s.png")
      base = Fixtures.simple_rig(32) |> Map.put("id", rig["id"])
      split = FramerWeb.Rig.enable_split(base, tolerance: 30, soft_edges: 8, edge_cleanup: 2)
      assert {:ok, _saved} = RigStore.save(split)

      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_change(view, "set_layer_tolerance", %{"tolerance" => "45"})

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.split?(saved)
      assert get_in(saved, ["layers", "tolerance"]) == 45
      assert get_in(saved, ["layers", "soft_edges"]) == 8
      assert get_in(saved, ["layers", "edge_cleanup"]) == 2
    end
  end

  describe "the background patch" do
    test "the panel offers the patch and its feather, and the feather is recorded", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})

      # The patch is a layer of its own, with a feather the user can move.
      assert has_element?(view, "#layer-row-patch")
      assert has_element?(view, "#compute-patch-btn")
      assert has_element?(view, "#layer-fade-form")

      render_change(view, "set_patch_fade", %{"fade" => "20"})

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.patch_fade(saved) == 20
      assert FramerWeb.Rig.has_patch_layer?(saved)
    end

    test "a negative feather is refused without touching the document", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})
      render_change(view, "set_patch_fade", %{"fade" => "-4"})

      assert render(view) =~ "The feather must be zero or more pixels"
      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.patch_fade(saved) == FramerWeb.Rig.default_fade()
    end

    test "the patch is computed from the skeleton and the preview points at it", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})

      # The rig has a skeleton now, so the engine materialised the patch beside
      # the still and the preview composites the very same bytes.
      assert RigStore.patch_path(rig["id"])
      assert File.exists?(RigStore.patch_path(rig["id"]))
      assert has_element?(view, "#viewport[data-patch-url]")

      # Asking for it again reuses the materialised patch rather than
      # recomputing it.
      render_click(view, "compute_patch", %{})
      assert render_async(view, 60_000) =~ "Patch computed"
      assert has_element?(view, "#viewport[data-patch-url]")
    end

    test "a feather change drops the materialised patch until it is computed again", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})

      # The materialised patch was built with the feather the document records.
      assert has_element?(view, "#layer-row-patch .badge-success")

      # Moving the feather makes the materialised patch stale, so it is
      # dropped: the panel reports it as not computed and the preview stops
      # compositing it.
      render_change(view, "set_patch_fade", %{"fade" => "20"})
      assert render(view) =~ "Not computed yet"
      refute RigStore.patch_path(rig["id"])
      refute has_element?(view, "#viewport[data-patch-url]")

      # Computing it again rebuilds the patch with the new feather.
      render_click(view, "compute_patch", %{})
      assert render_async(view, 60_000) =~ "Patch computed"
      assert has_element?(view, "#layer-row-patch .badge-success")
      assert has_element?(view, "#viewport[data-patch-url]")
    end

    test "a change of the motion drops the materialised patch", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})
      assert RigStore.patch_path(rig["id"])

      # Moving a bone changes the swept region, so the materialised patch no
      # longer describes it.
      render_click(view, "bone_moved", %{
        "id" => "b0",
        "head" => [20.0, 16.0],
        "tail" => [20.0, 8.0]
      })

      assert render(view) =~ "Not computed yet"
      refute RigStore.patch_path(rig["id"])
      refute has_element?(view, "#viewport[data-patch-url]")
    end

    test "the patch waits for the background plate it heals against", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})

      # Without the background layer there is no plate to heal against, so the
      # engine builds no patch and the editor says so instead of claiming one.
      render_click(view, "remove_layer", %{"layer" => "background"})
      render_click(view, "compute_patch", %{})

      assert render(view) =~ "The patch needs the background layer"
      assert render(view) =~ "Needs the background layer"
    end

    test "the feather slider does not evict the undo history", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      # A bone edit the user wants to be able to undo.
      render_click(view, "bone_moved", %{
        "id" => "b0",
        "head" => [20.0, 16.0],
        "tail" => [20.0, 8.0]
      })

      # A drag of the feather slider, one event per step.
      for fade <- 13..20 do
        render_change(view, "set_patch_fade", %{"fade" => to_string(fade)})
      end

      # Undo still steps back to the bone edit, not one pixel of the feather.
      render_click(view, "undo")

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.bone(saved, "b0")["rest"]["head"] == [16.0, 16.0]
    end

    test "the export materialises the patch in the project", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      id = rig["id"]
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

      render_click(view, "toggle_background_layer", %{})

      # The project's patch is gone, so the export has to materialise it: the
      # exported frames and the preview then composite the very same patch.
      RigStore.remove_patch_layer(id)
      refute RigStore.patch_path(id)

      render_submit(form(view, "#export-form"), %{"format" => "webm"})

      assert RigStore.patch_path(id)

      # Stop the orchestrator so the job does not outlive the test.
      if Process.whereis(FramerCore.Orchestrator) do
        try do
          state = FramerCore.Orchestrator.get_status()

          if state.job && state.job.status == :processing do
            GenServer.stop(FramerCore.Orchestrator, :shutdown, 2000)
          end
        catch
          :exit, _ -> :ok
        end
      end
    end

    test "the patch waits for a skeleton", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")

      # A split rig without bones: the region the character can uncover is only
      # known once the skeleton exists.
      split = FramerWeb.Rig.enable_split(FramerWeb.Rig.new(32, 32)) |> Map.put("id", rig["id"])
      _saved = RigStore.save(split)
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "compute_patch", %{})

      assert render(view) =~ "The patch needs a skeleton"
      refute RigStore.patch_path(rig["id"])
    end
  end

  describe "layers panel and per-layer actions" do
    test "panel lists project layers (source still, character, background)", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      assert has_element?(view, "#layers-panel")
      assert has_element?(view, "#project-layers-list")
      assert has_element?(view, "#layer-row-source")
      assert has_element?(view, "#layer-row-character")
      assert has_element?(view, "#layer-row-background")

      assert render(view) =~ "Source still"
      assert render(view) =~ "Character layer"
      assert render(view) =~ "Background layer"
    end

    test "removing the background layer leaves character alone (no-background outcome)", %{
      conn: conn
    } do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      # First extract character
      render_click(view, "toggle_background_layer", %{})
      assert has_element?(view, "#viewport[data-character-url]")
      assert has_element?(view, "#viewport[data-background-url]")

      # Now remove the background
      render_click(view, "remove_layer", %{"layer" => "background"})

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.has_character_layer?(saved)
      refute FramerWeb.Rig.has_background_layer?(saved)
      assert get_in(saved, ["layers", "background"]) == false

      # Viewport reflects no background: character URL present, background URL gone
      assert has_element?(view, "#viewport[data-character-url]")
      refute has_element?(view, "#viewport[data-background-url]")

      # Row displays removed badge and keep button
      assert has_element?(view, "#keep-background-btn")
      refute has_element?(view, "#remove-background-btn")

      # Restoring / keeping the background puts it back
      render_click(view, "keep_layer", %{"layer" => "background"})
      {:ok, restored} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.has_background_layer?(restored)
      assert has_element?(view, "#viewport[data-background-url]")
    end

    test "one-click background removal on unsplit rig extracts character and removes background",
         %{
           conn: conn
         } do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      # On unsplit rig, remove background directly
      render_click(view, "remove_background_initial", %{})

      {:ok, saved} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.split?(saved)
      assert FramerWeb.Rig.has_character_layer?(saved)
      refute FramerWeb.Rig.has_background_layer?(saved)

      assert has_element?(view, "#viewport[data-character-url]")
      refute has_element?(view, "#viewport[data-background-url]")
      assert has_element?(view, "#keep-background-btn")
    end

    test "render_frame with character extracted and background removed renders character alone with transparency",
         %{
           conn: conn
         } do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      # Extract character
      render_click(view, "toggle_background_layer", %{})
      # Remove background
      render_click(view, "remove_layer", %{"layer" => "background"})

      # Render frame
      render_click(view, "render_frame")
      rendered_html = render_async(view, 5000)
      assert rendered_html =~ "Server final render"
      assert has_element?(view, "#render-panel")

      [_, b64] = Regex.run(~r/data:image\/png;base64,([^"]+)/, rendered_html)
      png_bytes = Base.decode64!(b64)
      # PNG header + IHDR chunk (color type 6 = RGBA)
      assert <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", _w::32, _h::32, 8, 6,
               _rest::binary>> = png_bytes
    end

    test "removing and keeping the character layer", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})
      assert has_element?(view, "#viewport[data-character-url]")

      # Remove character
      render_click(view, "remove_layer", %{"layer" => "character"})
      {:ok, saved} = RigStore.load(rig["id"])
      refute FramerWeb.Rig.has_character_layer?(saved)
      refute has_element?(view, "#viewport[data-character-url]")
      assert has_element?(view, "#keep-character-btn")

      # Keep character
      render_click(view, "keep_layer", %{"layer" => "character"})
      {:ok, restored} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.has_character_layer?(restored)
      assert has_element?(view, "#viewport[data-character-url]")
    end

    test "replacing character and background layers via upload", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      render_click(view, "toggle_background_layer", %{})

      # Replace character
      char_upload =
        file_input(view, "#replace-layer-character-form", :replace_character, [
          %{name: "custom_hero.png", content: Fixtures.png(16, 16), type: "image/png"}
        ])

      render_upload(char_upload, "custom_hero.png")
      view |> form("#replace-layer-character-form") |> render_submit()

      {:ok, after_char} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.character_layer(after_char) =~ "character_replaced"
      assert File.exists?(RigStore.character_layer_path(rig["id"]))

      # Replace background
      bg_upload =
        file_input(view, "#replace-layer-background-form", :replace_background, [
          %{name: "custom_bg.png", content: Fixtures.png(16, 16), type: "image/png"}
        ])

      render_upload(bg_upload, "custom_bg.png")
      view |> form("#replace-layer-background-form") |> render_submit()

      {:ok, after_bg} = RigStore.load(rig["id"])
      assert FramerWeb.Rig.background_layer(after_bg) =~ "background_replaced"
      assert File.exists?(RigStore.plate_path(rig["id"]))
    end
  end

  describe "action feedback and blocking loader" do
    test "actions without a loaded rig surface error instead of silently failing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor")

      refute has_element?(view, "#editor-error")

      render_click(view, "save_rig")
      assert has_element?(view, "#editor-error")
      assert render(view) =~ "Load a rig first"

      render_click(view, "clear_error")
      refute has_element?(view, "#editor-error")

      render_click(view, "auto_bind")
      assert has_element?(view, "#editor-error")
      assert render(view) =~ "Load a rig first"

      render_click(view, "clear_error")
      refute has_element?(view, "#editor-error")

      render_click(view, "render_frame")
      assert has_element?(view, "#editor-error")
      assert render(view) =~ "Load a rig first"

      render_click(view, "clear_error")
      refute has_element?(view, "#editor-error")

      render_hook(view, "export", %{"format" => "webm"})
      assert has_element?(view, "#editor-error")
      assert render(view) =~ "Load a rig first"
    end

    test "render_frame displays blocking loader and opens rendered modal on completion", %{
      conn: conn
    } do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{rig["id"]}")

      refute has_element?(view, "#blocking-loader")

      # Triggering render_frame starts async task and immediately mounts blocking loader
      html = render_click(view, "render_frame")
      assert html =~ "Rendering frame 0"
      assert has_element?(view, "#blocking-loader")
      assert has_element?(view, "#blocking-loader-spinner")

      # Await async completion
      rendered_html = render_async(view, 5000)
      refute has_element?(view, "#blocking-loader")
      assert rendered_html =~ "Server final render"
      assert has_element?(view, "#render-panel")

      # Closing render panel dismisses it
      render_click(view, "close_render")
      refute has_element?(view, "#render-panel")
    end

    test "render_frame failure dismisses blocking loader and surfaces error in #editor-error", %{
      conn: conn
    } do
      {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))
      id = rig["id"]
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

      # Triggering render_frame without source fails and surfaces error while clearing loader
      render_click(view, "render_frame")
      render_async(view, 5000)
      refute has_element?(view, "#blocking-loader")
      assert has_element?(view, "#editor-error")
      assert render(view) =~ "Render failed"
    end

    test "export triggers blocking loader with honest progress, unblocks on completion, and surfaces failure",
         %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")
      _saved = RigStore.save(Fixtures.simple_rig(32) |> Map.put("id", rig["id"]))
      id = rig["id"]
      {:ok, view, _html} = live(conn, ~p"/editor?rig=#{id}")

      refute has_element?(view, "#blocking-loader")

      # Submit export
      render_submit(form(view, "#export-form"), %{"format" => "webm"})
      assert has_element?(view, "#blocking-loader")
      assert has_element?(view, "#blocking-loader-progress")
      assert render(view) =~ "Exporting animation"

      # Simulate progress update
      send(view.pid, :export_tick)
      assert has_element?(view, "#blocking-loader")

      # Completion unblocks the editor and shows download link
      completed_payload = %{
        job_id: "job-100",
        status: :completed,
        output: "/projects/#{id}/output.webm",
        progress: 100.0,
        result_url: "/api/rigs/#{id}/result"
      }

      Phoenix.PubSub.broadcast(
        FramerWeb.PubSub,
        FramerWeb.Renderer.topic(id),
        {:export, completed_payload}
      )

      refute has_element?(view, "#blocking-loader")
      assert has_element?(view, "a[download]")
      assert render(view) =~ "Export complete"

      # Failure payload dismisses blocking loader and surfaces error in #editor-error
      failed_payload = %{
        job_id: "job-101",
        status: :failed,
        output: "/projects/#{id}/output.webm",
        error: "Encoding failed: out of memory"
      }

      Phoenix.PubSub.broadcast(
        FramerWeb.PubSub,
        FramerWeb.Renderer.topic(id),
        {:export, failed_payload}
      )

      refute has_element?(view, "#blocking-loader")
      assert has_element?(view, "#editor-error")
      assert render(view) =~ "Encoding failed: out of memory"

      # Stop orchestrator if still processing so subsequent tests have a clean idle worker
      if Process.whereis(FramerCore.Orchestrator) do
        try do
          state = FramerCore.Orchestrator.get_status()

          if state.job && state.job.status == :processing do
            GenServer.stop(FramerCore.Orchestrator, :shutdown, 2000)
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end
end
