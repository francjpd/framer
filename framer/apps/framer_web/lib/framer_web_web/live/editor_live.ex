defmodule FramerWebWeb.EditorLive do
  @moduledoc """
  The rig/bones animation editor: a three-pane LiveView shell (tool palette,
  centre viewport, bottom timeline) over the engine's `deform` operation.

  LiveView owns the versioned rig document, the timeline and job submission.
  The centre viewport is a client-side canvas/WebGL2 preview (`LbsPreview`)
  that implements the same fixed-point inverse-LBS as the engine; structural
  edits round-trip through the server, pose edits stay local until the user
  records a keyframe. The BEAM never sees pixels: the server is handed the
  still path, the rig path, a frame range and the render options.

  The final render and the export are always produced by the engine (see
  `FramerWeb.Renderer`); the preview is explicitly a proxy of the same math.
  """

  use FramerWebWeb, :live_view

  alias FramerWeb.Renderer
  alias FramerWeb.Rig
  alias FramerWeb.RigStore

  @max_undo 40

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Framer Editor")
     |> assign(:projects, RigStore.list())
     |> assign(:rig, nil)
     |> assign(:selected_bone, nil)
     |> assign(:tool, "bones")
     |> assign(:playhead, 0)
     |> assign(:playing, false)
     |> assign(:pending_pose, %{})
     |> assign(:mesh_visible, true)
     |> assign(:labels_visible, false)
     |> assign(:graph_channel, "rot")
     |> assign(:undo, [])
     |> assign(:status, nil)
     |> assign(:error, nil)
     |> assign(:export, nil)
     |> assign(:rendered, nil)
     |> assign(:rendered_frame, nil)
     |> allow_upload(:source,
       accept: ~w(.png .jpg .jpeg .webp .bmp .gif),
       max_entries: 1,
       max_file_size: 25_000_000
     )}
  end

  @impl true
  def handle_params(%{"rig" => id}, _uri, socket) do
    case RigStore.load(id) do
      {:ok, rig} -> {:noreply, load_rig(socket, rig)}
      {:error, _reason} -> {:noreply, assign(socket, :error, "Could not load rig #{id}")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- rig lifecycle -------------------------------------------------------

  @impl true
  def handle_event("select_project", %{"id" => ""}, socket), do: {:noreply, socket}

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/editor?#{[rig: id]}")}
  end

  def handle_event("validate_source", _params, socket), do: {:noreply, socket}

  def handle_event("save_source", _params, socket) do
    case consume_uploaded_entries(socket, :source, fn %{path: path}, entry ->
           result =
             with {:ok, binary} <- File.read(path) do
               RigStore.create_from_source(binary, entry.client_name)
             end

           {:ok, result}
         end) do
      [{:ok, rig}] ->
        {:noreply, push_patch(socket, to: ~p"/editor?#{[rig: rig["id"]]}")}

      [{:error, reason}] ->
        {:noreply, assign(socket, :error, "Could not load image: #{format_reason(reason)}")}

      [] ->
        {:noreply, assign(socket, :error, "Choose an image first")}
    end
  end

  def handle_event("clear_error", _params, socket), do: {:noreply, assign(socket, :error, nil)}

  # --- tools / selection ---------------------------------------------------

  def handle_event("select_tool", %{"tool" => tool}, socket) when tool in ["bones", "pose"] do
    {:noreply, socket |> assign(:tool, tool) |> push_clear_overrides()}
  end

  def handle_event("select_bone", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_bone, id)}
  end

  def handle_event("toggle_mesh", _params, socket) do
    {:noreply, assign(socket, :mesh_visible, !socket.assigns.mesh_visible)}
  end

  def handle_event("toggle_labels", _params, socket) do
    {:noreply, assign(socket, :labels_visible, !socket.assigns.labels_visible)}
  end

  def handle_event("set_graph_channel", %{"channel" => channel}, socket)
      when channel in ["rot", "tx", "ty"] do
    {:noreply, assign(socket, :graph_channel, channel)}
  end

  def handle_event("set_graph_channel", _params, socket), do: {:noreply, socket}

  def handle_event("step_frame", %{"delta" => delta}, socket) do
    {:noreply,
     socket
     |> assign(
       playhead: clamp_frame(socket, socket.assigns.playhead + to_int(delta)),
       pending_pose: %{}
     )
     |> push_clear_overrides()}
  end

  def handle_event("step_frame", _params, socket), do: {:noreply, socket}

  # --- bone edits ----------------------------------------------------------

  def handle_event("bone_created", %{"head" => head, "tail" => tail} = params, socket) do
    parent = blank_to_nil(params["parent"])
    socket = maybe_push_undo(socket, [])
    {rig, id} = Rig.add_bone(socket.assigns.rig, head, tail, parent: parent)

    socket =
      socket
      |> finalize_mutation(rig, [])
      |> assign(:selected_bone, id)

    {:noreply, socket}
  end

  def handle_event("bone_moved", %{"id" => id, "head" => head, "tail" => tail}, socket) do
    {:noreply, mutate(socket, fn rig -> Rig.move_bone(rig, id, head, tail) end)}
  end

  def handle_event("bone_translated", %{"id" => id, "dx" => dx, "dy" => dy}, socket) do
    {:noreply, mutate(socket, fn rig -> Rig.translate_bone(rig, id, dx, dy) end)}
  end

  def handle_event("bone_deleted", %{"id" => id}, socket) do
    {:noreply, mutate(socket, fn rig -> Rig.delete_bone(rig, id) end)}
  end

  def handle_event("bone_parented", %{"id" => id, "parent" => parent}, socket) do
    {:noreply, mutate(socket, fn rig -> Rig.set_parent(rig, id, blank_to_nil(parent)) end)}
  end

  def handle_event("set_radius", %{"id" => id, "radius" => radius}, socket) do
    case to_float(radius) do
      value when is_number(value) and value > 0 ->
        {:noreply, mutate(socket, fn rig -> Rig.set_radius(rig, id, value) end)}

      _ ->
        {:noreply, assign(socket, :error, "Radius must be a positive number")}
    end
  end

  def handle_event("set_falloff", %{"id" => id, "falloff" => falloff}, socket) do
    if falloff in Rig.falloffs() do
      {:noreply, mutate(socket, fn rig -> Rig.set_falloff(rig, id, falloff) end)}
    else
      {:noreply, assign(socket, :error, "Unknown falloff; expected smooth, linear or hard")}
    end
  end

  def handle_event("set_bind", params, socket) do
    opts = [power: to_float(params["power"]), radius_scale: to_float(params["radius_scale"])]
    {:noreply, mutate(socket, fn rig -> Rig.set_bind(rig, opts) end)}
  end

  def handle_event("auto_bind", _params, socket) do
    {:noreply,
     mutate(socket, fn rig -> Rig.auto_bind(rig) end,
       status: "Bound the control mesh to the bones"
     )}
  end

  # --- undo ----------------------------------------------------------------

  def handle_event("undo", _params, %{assigns: %{undo: [previous | rest]}} = socket) do
    {:noreply, socket |> assign(:undo, rest) |> finalize_mutation(previous, [])}
  end

  def handle_event("undo", _params, socket), do: {:noreply, socket}

  # --- timeline ------------------------------------------------------------

  def handle_event("set_playhead", %{"frame" => frame}, socket) do
    {:noreply,
     socket
     |> assign(playhead: clamp_frame(socket, frame), pending_pose: %{})
     |> push_clear_overrides()}
  end

  def handle_event("pose_changed", %{"pose" => pose}, socket) do
    {:noreply, assign(socket, :pending_pose, pose || %{})}
  end

  def handle_event("record_keyframe", _params, socket) do
    frame = socket.assigns.playhead

    socket =
      mutate(socket, fn rig -> Rig.record_keyframe(rig, frame, socket.assigns.pending_pose) end,
        status: "Recorded keyframe at frame #{frame}"
      )

    {:noreply, socket |> assign(:pending_pose, %{}) |> push_clear_overrides()}
  end

  def handle_event("delete_keyframe", _params, socket) do
    frame = socket.assigns.playhead

    {:noreply,
     mutate(socket, fn rig -> Rig.delete_keyframe(rig, frame) end,
       status: "Deleted keyframe at frame #{frame}"
     )}
  end

  def handle_event("toggle_play", _params, socket) do
    if socket.assigns.playing do
      {:noreply, assign(socket, :playing, false)}
    else
      {:noreply,
       socket
       |> assign(playing: true, pending_pose: %{})
       |> push_clear_overrides()
       |> schedule_tick()}
    end
  end

  def handle_event("toggle_loop", _params, %{assigns: %{rig: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_loop", _params, socket) do
    loop = !loop?(socket.assigns.rig)

    rig =
      Map.put(
        socket.assigns.rig,
        "playback",
        Map.put(socket.assigns.rig["playback"] || %{}, "loop", loop)
      )

    {:noreply, mutate(socket, fn _ -> rig end)}
  end

  # --- render / export -----------------------------------------------------

  def handle_event("render_frame", _params, %{assigns: %{rig: nil}} = socket),
    do: {:noreply, assign(socket, :error, "Load a rig first")}

  def handle_event("render_frame", _params, socket) do
    frame = socket.assigns.playhead

    case Renderer.render_frame(socket.assigns.rig, frame) do
      {:ok, binary} ->
        {:noreply, assign(socket, rendered: binary, rendered_frame: frame, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Render failed: #{format_reason(reason)}")}
    end
  end

  def handle_event("close_render", _params, socket) do
    {:noreply, assign(socket, rendered: nil, rendered_frame: nil)}
  end

  def handle_event("export", _params, %{assigns: %{rig: nil}} = socket),
    do: {:noreply, assign(socket, :error, "Load a rig first")}

  def handle_event("export", params, socket) do
    case Renderer.submit_export(socket.assigns.rig, format: params["format"] || "webm") do
      {:ok, export} ->
        {:noreply,
         socket
         |> assign(:export, %{
           job_id: export.job_id,
           status: :processing,
           progress: 0.0,
           output: Path.basename(export.output),
           result_url: ~p"/api/rigs/#{socket.assigns.rig["id"]}/result"
         })
         |> assign(:error, nil)
         |> schedule_export_tick()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Export failed: #{format_reason(reason)}")}
    end
  end

  def handle_event("save_rig", _params, %{assigns: %{rig: nil}} = socket), do: {:noreply, socket}

  def handle_event("save_rig", _params, socket) do
    {:noreply,
     socket
     |> finalize_mutation(socket.assigns.rig, [])
     |> assign(:status, "Saved")}
  end

  # --- timers / pubsub -----------------------------------------------------

  @impl true
  def handle_info(:tick, %{assigns: %{playing: false}} = socket), do: {:noreply, socket}

  def handle_info(:tick, %{assigns: %{rig: nil}} = socket),
    do: {:noreply, assign(socket, :playing, false)}

  def handle_info(:tick, socket) do
    frames = Rig.frame_count(socket.assigns.rig)
    next = socket.assigns.playhead + 1

    cond do
      next >= frames and loop?(socket.assigns.rig) ->
        {:noreply, assign(socket, playhead: 0) |> schedule_tick()}

      next >= frames ->
        {:noreply, assign(socket, playing: false, playhead: frames - 1)}

      true ->
        {:noreply, assign(socket, playhead: next) |> schedule_tick()}
    end
  end

  def handle_info(:export_tick, %{assigns: %{export: nil}} = socket), do: {:noreply, socket}

  def handle_info(:export_tick, %{assigns: %{export: %{status: status}}} = socket)
      when status in [:completed, :failed],
      do: {:noreply, socket}

  def handle_info(:export_tick, socket) do
    export = socket.assigns.export
    progress = export_progress(FramerCore.Orchestrator.get_status(), export)

    {:noreply,
     socket
     |> assign(:export, %{export | progress: progress})
     |> schedule_export_tick()}
  end

  def handle_info({:export, payload}, socket) do
    rig = socket.assigns.rig

    if rig && is_binary(payload[:output]) && String.contains?(payload[:output], rig["id"]) do
      {:noreply, apply_export_result(socket, payload)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # --- rendering -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="editor-shell"
      phx-hook="EditorKeys"
      data-frames={@rig && Rig.frame_count(@rig)}
      class="flex h-screen flex-col bg-base-100 text-base-content"
    >
      <header class="flex flex-wrap items-center gap-3 border-b border-base-300 px-4 py-2">
        <h1 class="text-sm font-semibold">Framer Editor</h1>
        <span class="badge badge-ghost badge-xs">framer.rig v{Rig.version()}</span>
        <span class="hidden text-[11px] opacity-50 md:inline">
          space play · K keyframe · ←/→ step · ⌘Z undo
        </span>

        <div class="ml-auto flex items-center gap-2">
          <span :if={@status} class="text-xs text-success">{@status}</span>
          <span :if={@rig} class="hidden font-mono text-xs opacity-70 sm:inline">
            {@rig["name"]} · {Rig.frame_count(@rig)}f @ {Rig.fps(@rig)}fps
          </span>
          <button phx-click="undo" class="btn btn-xs" disabled={@undo == []}>Undo</button>
          <button phx-click="save_rig" class="btn btn-xs">Save</button>
        </div>
      </header>

      <div
        :if={@error}
        id="editor-error"
        role="alert"
        class="flex items-center gap-2 border-b border-error/40 bg-error/15 px-4 py-1 text-xs text-error"
      >
        <span class="font-semibold">!</span>
        <span>{@error}</span>
        <button phx-click="clear_error" class="btn btn-ghost btn-xs ml-auto">dismiss</button>
      </div>

      <div class="flex min-h-0 flex-1">
        <.palette
          rig={@rig}
          projects={@projects}
          upload={@uploads.source}
          tool={@tool}
          selected={selected_bone(@rig, @selected_bone)}
        />
        <.viewport
          rig={@rig}
          playhead={@playhead}
          tool={@tool}
          selected={@selected_bone}
          mesh_visible={@mesh_visible}
          labels_visible={@labels_visible}
        />
      </div>

      <.timeline
        rig={@rig}
        playhead={@playhead}
        playing={@playing}
        pending_pose={@pending_pose}
        selected={selected_bone(@rig, @selected_bone)}
        graph_channel={@graph_channel}
      />
      <.export_panel export={@export} />
      <.render_panel rendered={@rendered} frame={@rendered_frame} />
    </div>
    """
  end

  # --- components ----------------------------------------------------------

  attr :rig, :map, default: nil
  attr :projects, :list, default: []
  attr :upload, :any, required: true
  attr :tool, :string, required: true
  attr :selected, :map, default: nil

  defp palette(assigns) do
    ~H"""
    <aside class="flex w-64 flex-col gap-4 overflow-y-auto border-r border-base-300 p-3 text-xs">
      <section>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Media</h2>
        <.upload_form upload={@upload} />
        <ul class="mt-2 flex flex-col gap-1">
          <li :for={project <- @projects}>
            <button
              phx-click="select_project"
              phx-value-id={project.id}
              class={[
                "btn btn-xs w-full justify-start gap-2",
                @rig && @rig["id"] == project.id && "btn-active"
              ]}
            >
              <span class="truncate">{project.name}</span>
              <span class="ml-auto opacity-50">{project.bones} bones</span>
            </button>
          </li>
        </ul>
        <p :if={@projects == []} class="mt-2 opacity-60">No projects yet - load a still image.</p>
      </section>

      <section>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Tools</h2>
        <div class="flex flex-col gap-1">
          <button
            phx-click="select_tool"
            phx-value-tool="bones"
            class={["btn btn-xs justify-start gap-2", @tool == "bones" && "btn-primary"]}
          >
            Bones
          </button>
          <button
            phx-click="select_tool"
            phx-value-tool="pose"
            class={["btn btn-xs justify-start gap-2", @tool == "pose" && "btn-primary"]}
          >
            Pose
          </button>
        </div>
        <p class="mt-2 opacity-60">
          <span :if={@tool == "bones"}>
            Drag empty canvas to create a bone, a joint to move it, the body to translate.
          </span>
          <span :if={@tool == "pose"}>
            Drag a joint to rotate and the body to translate, then record a keyframe.
          </span>
        </p>
      </section>

      <section :if={@rig}>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Hierarchy</h2>
        <ul class="flex flex-col gap-0.5">
          <li :for={{bone, depth} <- bone_tree(@rig)}>
            <div
              class={[
                "flex items-center gap-1 rounded px-1 py-0.5",
                @selected && @selected["id"] == bone["id"] && "bg-primary/20"
              ]}
              style={"margin-left: #{depth * 10}px"}
            >
              <button
                phx-click="select_bone"
                phx-value-id={bone["id"]}
                class="flex-1 truncate text-left"
                title={bone["id"]}
              >
                <span :if={depth > 0} class="opacity-40">└ </span>{bone["name"] || bone["id"]}
              </button>
              <span class="opacity-50">r{trunc(bone["radius"] || 0)}</span>
              <button phx-click="bone_deleted" phx-value-id={bone["id"]} class="btn btn-ghost btn-xs">
                ×
              </button>
            </div>
          </li>
        </ul>
        <ul :if={bone_tree(@rig) == []} class="opacity-60">
          <li>No bones yet - draw one in the viewport.</li>
        </ul>
      </section>

      <section :if={@rig}>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Bone properties</h2>
        <div :if={@selected}>
          <p class="mb-1 font-mono opacity-70">{@selected["id"]}</p>
          <form id="bone-properties-form">
            <label class="label-text">Radius</label>
            <input
              type="range"
              min="1"
              max={max(Rig.width(@rig), Rig.height(@rig))}
              value={@selected["radius"]}
              phx-change="set_radius"
              phx-value-id={@selected["id"]}
              name="radius"
              class="range range-xs"
            />
            <p class="opacity-60">{trunc(@selected["radius"] || 0)} px</p>
            <label class="label-text">Falloff</label>
            <select
              phx-change="set_falloff"
              phx-value-id={@selected["id"]}
              name="falloff"
              class="select select-xs select-bordered w-full"
            >
              <option
                :for={f <- ~w(smooth linear hard)}
                value={f}
                selected={(@selected["falloff"] || "smooth") == f}
              >
                {f}
              </option>
            </select>
            <label class="label-text mt-2">Parent</label>
            <select
              phx-change="bone_parented"
              phx-value-id={@selected["id"]}
              name="parent"
              class="select select-xs select-bordered w-full"
            >
              <option value="" selected={is_nil(@selected["parent"])}>none</option>
              <option
                :for={bone <- Rig.bones(@rig)}
                :if={bone["id"] != @selected["id"]}
                value={bone["id"]}
                selected={@selected["parent"] == bone["id"]}
              >
                {bone["name"] || bone["id"]}
              </option>
            </select>
          </form>
        </div>
        <div :if={!@selected} class="opacity-60">Select a bone.</div>
      </section>

      <section>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Bind</h2>
        <p :if={@rig == nil} class="opacity-60">Load a rig to bind.</p>
        <div :if={@rig}>
          <form id="bind-form">
            <label class="label-text">Power</label>
            <input
              type="range"
              min="0.5"
              max="6"
              step="0.1"
              value={get_in(@rig, ["bind", "power"]) || 2.0}
              phx-change="set_bind"
              name="power"
              class="range range-xs"
            />
            <label class="label-text">Radius scale</label>
            <input
              type="range"
              min="0.25"
              max="4"
              step="0.05"
              value={get_in(@rig, ["bind", "radius_scale"]) || 1.0}
              phx-change="set_bind"
              name="radius_scale"
              class="range range-xs"
            />
          </form>
        </div>
        <button
          phx-click="auto_bind"
          class="btn btn-xs mt-2 w-full"
          disabled={@rig == nil}
        >
          Auto-bind mesh
        </button>
      </section>
    </aside>
    """
  end

  attr :upload, :any, required: true

  defp upload_form(assigns) do
    ~H"""
    <form
      id="upload-form"
      phx-change="validate_source"
      phx-submit="save_source"
      class="flex flex-col gap-1"
    >
      <.live_file_input upload={@upload} class="file-input file-input-xs file-input-bordered w-full" />
      <button type="submit" class="btn btn-xs btn-primary w-full">Load image</button>
    </form>
    """
  end

  attr :rig, :map, default: nil
  attr :playhead, :integer, required: true
  attr :tool, :string, required: true
  attr :selected, :string, default: nil
  attr :mesh_visible, :boolean, default: true
  attr :labels_visible, :boolean, default: false

  defp viewport(assigns) do
    ~H"""
    <section class="relative min-h-0 flex-1 bg-neutral-950">
      <div class="absolute left-2 top-2 z-10 flex items-center gap-1">
        <button
          phx-click="toggle_mesh"
          class={["btn btn-xs", @mesh_visible && "btn-active"]}
          title="Show or hide the control mesh"
        >
          Mesh
        </button>
        <button
          phx-click="toggle_labels"
          class={["btn btn-xs", @labels_visible && "btn-active"]}
          title="Show or hide bone names"
        >
          Labels
        </button>
        <span class="badge badge-ghost badge-xs">proxy preview</span>
      </div>
      <div
        :if={@rig}
        id="viewport"
        phx-hook="LbsPreview"
        data-source-url={~p"/api/rigs/#{@rig["id"]}/source"}
        data-frame={@playhead}
        data-tool={@tool}
        data-selected={@selected || ""}
        data-mesh={to_string(@mesh_visible)}
        data-labels={to_string(@labels_visible)}
        class="absolute inset-0"
      >
        <div id="viewport-surface" phx-update="ignore" class="absolute inset-0"></div>
      </div>
      <div :if={!@rig} class="flex h-full items-center justify-center text-sm opacity-60">
        Load a still image to start rigging.
      </div>
    </section>
    """
  end

  attr :rig, :map, default: nil
  attr :playhead, :integer, required: true
  attr :playing, :boolean, required: true
  attr :pending_pose, :map, required: true
  attr :selected, :map, default: nil
  attr :graph_channel, :string, default: "rot"

  defp timeline(assigns) do
    assigns =
      assign(
        assigns,
        :graph,
        graph_for(assigns.rig, assigns.selected, assigns.graph_channel, assigns.playhead)
      )

    ~H"""
    <footer class="border-t border-base-300 bg-base-200/40 px-3 py-2 text-xs">
      <div :if={@rig == nil} class="opacity-60">Timeline appears once a rig is loaded.</div>

      <div :if={@rig} class="flex flex-col gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <div class="join">
            <button
              phx-click="set_playhead"
              phx-value-frame="0"
              class="btn btn-xs join-item"
              title="Jump to start (Home)"
            >
              ⏮
            </button>
            <button
              phx-click="step_frame"
              phx-value-delta="-1"
              class="btn btn-xs join-item"
              title="Previous frame (←)"
            >
              ◀
            </button>
            <button
              phx-click="toggle_play"
              class="btn btn-xs join-item w-20"
              title="Play / pause (space)"
            >
              {if @playing, do: "❚❚ Pause", else: "▶ Play"}
            </button>
            <button
              phx-click="step_frame"
              phx-value-delta="1"
              class="btn btn-xs join-item"
              title="Next frame (→)"
            >
              ▶
            </button>
            <button
              phx-click="set_playhead"
              phx-value-frame={Rig.frame_count(@rig) - 1}
              class="btn btn-xs join-item"
              title="Jump to end (End)"
            >
              ⏭
            </button>
            <button
              phx-click="toggle_loop"
              class={["btn btn-xs join-item", loop?(@rig) && "btn-active"]}
              title="Loop playback"
            >
              ↻
            </button>
          </div>

          <button
            phx-click="record_keyframe"
            class="btn btn-xs btn-primary"
            title="Record keyframe (K)"
          >
            ◆ Record keyframe
          </button>
          <button phx-click="delete_keyframe" class="btn btn-xs" title="Delete keyframe">
            ◇ Delete keyframe
          </button>

          <span class="font-mono">
            frame {@playhead} / {Rig.frame_count(@rig) - 1} · {Rig.fps(@rig)} fps
          </span>
          <span :if={map_size(@pending_pose) > 0} class="text-warning">pose pending</span>

          <span class="ml-auto flex items-center gap-2">
            <button phx-click="render_frame" class="btn btn-xs">Render frame</button>
            <form phx-submit="export" class="flex items-center gap-1">
              <select name="format" class="select select-xs select-bordered">
                <option value="webm">webm</option>
                <option value="mp4">mp4</option>
                <option value="gif">gif</option>
              </select>
              <button type="submit" class="btn btn-xs btn-accent">Export</button>
            </form>
          </span>
        </div>

        <div class="flex items-center gap-1 font-mono text-[10px] opacity-60">
          <span class="w-10 shrink-0">frame</span>
          <div class="relative h-4 flex-1">
            <button
              :for={tick <- tick_frames(Rig.frame_count(@rig))}
              phx-click="set_playhead"
              phx-value-frame={tick}
              class="absolute -translate-x-1/2 hover:opacity-100"
              style={"left: #{playhead_percent(tick, Rig.frame_count(@rig))}%"}
            >
              {tick}
            </button>
          </div>
        </div>

        <div
          id="timeline-track"
          phx-hook="TimelineScrub"
          data-frames={Rig.frame_count(@rig)}
          data-frame={@playhead}
          class="relative h-14 cursor-pointer overflow-hidden rounded bg-base-300/60"
        >
          <div class="absolute left-1 top-1 rounded bg-base-100/60 px-1 text-[9px] uppercase opacity-50">
            keys
          </div>
          <button
            :for={keyframe <- Rig.keyframes(@rig)}
            phx-click="set_playhead"
            phx-value-frame={keyframe["frame"]}
            title={"keyframe #{keyframe["frame"]}"}
            class="absolute top-2 h-3 w-3 -translate-x-1/2 rotate-45 rounded-sm bg-accent"
            style={"left: #{playhead_percent(keyframe["frame"], Rig.frame_count(@rig))}%"}
          >
          </button>

          <div class="absolute left-1 top-7 rounded bg-base-100/60 px-1 text-[9px] uppercase opacity-50">
            {(@selected && (@selected["name"] || @selected["id"])) || "bone"}
          </div>
          <button
            :for={keyframe <- selected_keyframes(@rig, @selected)}
            phx-click="set_playhead"
            phx-value-frame={keyframe["frame"]}
            title={"selected bone keyframe #{keyframe["frame"]}"}
            class="absolute top-8 h-3 w-3 -translate-x-1/2 rotate-45 rounded-sm bg-primary"
            style={"left: #{playhead_percent(keyframe["frame"], Rig.frame_count(@rig))}%"}
          >
          </button>

          <div
            class="absolute top-0 h-full w-px bg-primary"
            style={"left: #{playhead_percent(@playhead, Rig.frame_count(@rig))}%"}
          >
          </div>
        </div>

        <div :if={@graph} class="flex items-center gap-2">
          <div class="join">
            <button
              :for={channel <- ~w(rot tx ty)}
              phx-click="set_graph_channel"
              phx-value-channel={channel}
              class={["btn btn-xs join-item", @graph_channel == channel && "btn-active"]}
              title={"#{channel} value / velocity"}
            >
              {channel}
            </button>
          </div>
          <svg
            viewBox="0 0 1000 100"
            preserveAspectRatio="none"
            class="h-12 flex-1 rounded bg-base-300/60"
          >
            <polyline
              points={@graph.velocity}
              fill="none"
              class="stroke-warning/70"
              stroke-dasharray="4 3"
              stroke-width="2"
            />
            <polyline points={@graph.value} fill="none" class="stroke-accent" stroke-width="2" />
            <line
              x1={@graph.playhead_x}
              y1="0"
              x2={@graph.playhead_x}
              y2="100"
              class="stroke-primary"
              stroke-width="2"
            />
            <circle :for={{x, y} <- @graph.keys} cx={x} cy={y} r="3" class="fill-primary" />
          </svg>
          <span class="w-28 text-right font-mono opacity-70">
            {@graph.channel} {@graph.current}
          </span>
        </div>
        <p :if={@graph == nil} class="opacity-50">
          Select a bone to see its value and velocity graph.
        </p>
      </div>
    </footer>
    """
  end

  attr :export, :map, default: nil

  defp export_panel(assigns) do
    ~H"""
    <div :if={@export} class="border-t border-base-300 bg-base-200 px-4 py-2 text-xs">
      <div class="flex flex-wrap items-center gap-3">
        <span class="font-semibold">Export</span>
        <span>{@export.status}</span>
        <progress class="progress progress-primary w-40" value={@export.progress} max="100">
        </progress>
        <span>{@export.progress}%</span>
        <a
          :if={@export.status == :completed}
          href={@export.result_url}
          class="btn btn-xs btn-success"
          download
        >
          Download {@export.output}
        </a>
        <span :if={@export.status == :failed} class="text-error">{@export[:error]}</span>
      </div>
    </div>
    """
  end

  attr :rendered, :any, default: nil
  attr :frame, :integer, default: nil

  defp render_panel(assigns) do
    ~H"""
    <div
      :if={@rendered}
      id="render-panel"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-8"
    >
      <div class="flex max-h-full max-w-3xl flex-col gap-2 rounded bg-base-100 p-3">
        <div class="flex items-center gap-3 text-xs">
          <span class="font-semibold">Server final render · frame {@frame}</span>
          <button phx-click="close_render" class="btn btn-xs ml-auto">Close</button>
        </div>
        <img
          src={"data:image/png;base64,#{Base.encode64(@rendered)}"}
          class="max-h-[70vh] object-contain"
        />
      </div>
    </div>
    """
  end

  # --- helpers -------------------------------------------------------------

  # --- timeline graph helpers ----------------------------------------------

  # Hierarchy order with indentation depth, following parent links.
  defp bone_tree(rig) do
    by_parent = Enum.group_by(Rig.bones(rig), & &1["parent"])

    walk = fn walk, parent, depth ->
      (by_parent[parent] || [])
      |> Enum.flat_map(fn bone -> [{bone, depth} | walk.(walk, bone["id"], depth + 1)] end)
    end

    walk.(walk, nil, 0)
  end

  defp selected_keyframes(_rig, nil), do: []

  defp selected_keyframes(rig, selected) do
    Enum.filter(Rig.keyframes(rig), &(get_in(&1, ["pose", selected["id"]]) != nil))
  end

  # Frame ruler ticks, roughly ten labels across the range.
  defp tick_frames(frames) when frames <= 1, do: [0]

  defp tick_frames(frames) do
    step = max(1, div(frames, 10))
    0..(frames - 1) |> Enum.filter(&(rem(&1, step) == 0))
  end

  defp graph_for(nil, _selected, _channel, _playhead), do: nil
  defp graph_for(_rig, nil, _channel, _playhead), do: nil

  defp graph_for(rig, selected, channel, playhead) do
    frames = Rig.frame_count(rig)
    bone_id = selected["id"]
    series = channel_series(rig, bone_id, channel)
    {min, max} = bounds(Enum.map(series, &elem(&1, 1)))

    velocity = velocity_series(series, Rig.fps(rig))
    {vmin, vmax} = bounds(Enum.map(velocity, &elem(&1, 1)))

    x = fn frame -> if frames <= 1, do: 0.0, else: frame / (frames - 1) * 1000 end

    point = fn frame, value, low, high -> {x.(frame), norm_y(value, low, high)} end

    keys =
      rig
      |> Rig.keyframes()
      |> Enum.sort_by(& &1["frame"])
      |> Enum.map(fn keyframe ->
        point.(keyframe["frame"], pose_value(rig, bone_id, channel, keyframe["frame"]), min, max)
      end)

    %{
      channel: channel,
      value:
        Enum.map_join(series, " ", fn {frame, value} ->
          point_str(point.(frame, value, min, max))
        end),
      velocity:
        Enum.map_join(velocity, " ", fn {frame, value} ->
          point_str(point.(frame, value, vmin, vmax))
        end),
      keys: keys,
      playhead_x: Float.round(x.(playhead), 2),
      current: Float.round(pose_value(rig, bone_id, channel, playhead), 3)
    }
  end

  defp channel_series(rig, bone_id, channel) do
    frames = Rig.frame_count(rig)

    for frame <- 0..max(frames - 1, 0) do
      {frame, pose_value(rig, bone_id, channel, frame)}
    end
  end

  # Linear interpolation between sorted keyframes, matching `lbs.mjs`.
  defp interpolated_pose(rig, bone_id, frame) do
    case Enum.sort_by(Rig.keyframes(rig), & &1["frame"]) do
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

  defp pose_value(rig, bone_id, channel, frame) do
    interpolated_pose(rig, bone_id, frame) |> Map.get(channel, 0.0)
  end

  defp velocity_series(series, fps) do
    series
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{frame, value}, {_next_frame, next}] -> {frame, (next - value) * fps} end)
  end

  defp bounds([]), do: {0.0, 0.0}
  defp bounds(values), do: {Enum.min(values), Enum.max(values)}

  defp norm_y(value, min, max) do
    span = max - min
    if span < 1.0e-9, do: 50.0, else: 100.0 - (value - min) / span * 100.0
  end

  defp point_str({x, y}), do: "#{Float.round(x, 2)},#{Float.round(y, 2)}"

  defp to_number(value) when is_number(value), do: value * 1.0
  defp to_number(_), do: 0.0

  defp load_rig(socket, rig) do
    if socket.assigns.rig && socket.assigns.rig["id"] != rig["id"] do
      Phoenix.PubSub.unsubscribe(FramerWeb.PubSub, Renderer.topic(socket.assigns.rig["id"]))
    end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(FramerWeb.PubSub, Renderer.topic(rig["id"]))
    end

    first = List.first(Rig.bones(rig))

    socket
    |> assign(:rig, rig)
    |> assign(:projects, RigStore.list())
    |> assign(:selected_bone, first && first["id"])
    |> assign(:playhead, 0)
    |> assign(:pending_pose, %{})
    |> assign(:graph_channel, "rot")
    |> assign(:undo, [])
    |> assign(:error, nil)
    |> assign(:export, nil)
    |> assign(:rendered, nil)
    |> push_rig()
  end

  defp mutate(socket, fun, opts \\ []) do
    socket = maybe_push_undo(socket, opts)

    case fun.(socket.assigns.rig) do
      {:error, reason} -> assign(socket, :error, format_reason(reason))
      {:ok, rig} when is_map(rig) -> finalize_mutation(socket, rig, opts)
      rig when is_map(rig) -> finalize_mutation(socket, rig, opts)
    end
  end

  defp finalize_mutation(socket, rig, opts) do
    socket
    |> assign(:rig, rig)
    |> assign(:status, opts[:status])
    |> assign(:error, nil)
    |> prune_selection()
    |> persist(rig)
    |> push_rig()
  end

  defp persist(socket, rig) do
    case RigStore.save(rig) do
      {:ok, saved} ->
        socket
        |> assign(:rig, saved)
        |> assign(:projects, RigStore.list())

      {:error, reason} ->
        assign(socket, :error, "Could not save rig: #{format_reason(reason)}")
    end
  end

  defp prune_selection(socket) do
    rig = socket.assigns.rig
    selected = socket.assigns.selected_bone

    if selected && rig && !Rig.bone(rig, selected) do
      assign(socket, :selected_bone, nil)
    else
      socket
    end
  end

  defp push_rig(socket) do
    if socket.assigns.rig do
      push_event(socket, "rig", %{rig: socket.assigns.rig})
    else
      socket
    end
  end

  defp push_clear_overrides(socket), do: push_event(socket, "clear_overrides", %{})

  defp maybe_push_undo(socket, opts) do
    if Keyword.get(opts, :undo, true) && socket.assigns.rig do
      update(socket, :undo, &Enum.take([socket.assigns.rig | &1], @max_undo))
    else
      socket
    end
  end

  defp schedule_tick(socket) do
    interval = max(16, round(1000 / max(Rig.fps(socket.assigns.rig), 1)))
    Process.send_after(self(), :tick, interval)
    socket
  end

  defp schedule_export_tick(socket) do
    Process.send_after(self(), :export_tick, 400)
    socket
  end

  defp export_progress(state, export) do
    cond do
      state.job && state.job.id == export.job_id && state.total_chunks > 0 ->
        done = length(state.completed_chunks) + length(state.failed_chunks)
        Float.round(done / state.total_chunks * 100, 1)

      true ->
        export.progress
    end
  end

  defp apply_export_result(socket, payload) do
    export =
      socket.assigns.export ||
        %{output: payload[:output], result_url: nil, progress: 0.0, status: :processing}

    socket
    |> assign(:export, Map.merge(export, payload))
    |> assign(:status, if(payload[:status] == :completed, do: "Export complete", else: nil))
  end

  defp selected_bone(_rig, nil), do: nil
  defp selected_bone(nil, _id), do: nil
  defp selected_bone(rig, id), do: Rig.bone(rig, id)

  defp clamp_frame(socket, frame) do
    frames = if socket.assigns.rig, do: Rig.frame_count(socket.assigns.rig), else: 1
    frame |> to_int() |> max(0) |> min(max(frames - 1, 0))
  end

  defp playhead_percent(_frame, frames) when frames <= 1, do: 0.0

  defp playhead_percent(frame, frames) do
    Float.round(frame / (frames - 1) * 100, 3)
  end

  defp loop?(rig), do: get_in(rig, ["playback", "loop"]) || false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp to_float(_), do: nil

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason({:invalid_rig, reason}), do: reason
  defp format_reason(reason), do: inspect(reason)
end
