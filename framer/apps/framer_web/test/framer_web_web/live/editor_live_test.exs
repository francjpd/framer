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
end
