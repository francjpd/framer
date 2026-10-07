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
  def handle_event("request_rig", _params, socket), do: {:noreply, push_rig(socket)}

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
    {:noreply, mutate(socket, fn rig -> Rig.set_radius(rig, id, to_float(radius)) end)}
  end

  def handle_event("set_falloff", %{"id" => id, "falloff" => falloff}, socket) do
    {:noreply, mutate(socket, fn rig -> Rig.set_falloff(rig, id, falloff) end)}
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
    <div id="editor-shell" class="flex h-screen flex-col bg-base-100 text-base-content">
      <header class="flex flex-wrap items-center gap-3 border-b border-base-300 px-4 py-2">
        <h1 class="text-sm font-semibold">Framer Editor</h1>

        <form phx-change="select_project" class="flex items-center gap-2">
          <select name="id" class="select select-xs select-bordered">
            <option value="">Switch rig…</option>
            <option
              :for={project <- @projects}
              value={project.id}
              selected={@rig && project.id == @rig["id"]}
            >
              {project.name} · {project.bones} bones
            </option>
          </select>
        </form>

        <form
          id="upload-form"
          phx-change="validate_source"
          phx-submit="save_source"
          class="flex items-center gap-2"
        >
          <.live_file_input upload={@uploads.source} class="file-input file-input-xs" />
          <button type="submit" class="btn btn-xs btn-primary">Load image</button>
        </form>

        <div class="ml-auto flex items-center gap-2">
          <span :if={@status} class="text-xs text-success">{@status}</span>
          <button phx-click="undo" class="btn btn-xs" disabled={@undo == []}>Undo</button>
          <button phx-click="save_rig" class="btn btn-xs">Save</button>
        </div>
      </header>

      <div
        :if={@error}
        id="editor-error"
        class="flex items-center gap-2 bg-error/15 px-4 py-1 text-xs text-error"
      >
        <span>{@error}</span>
        <button phx-click="clear_error" class="btn btn-ghost btn-xs">dismiss</button>
      </div>

      <div class="flex min-h-0 flex-1">
        <.palette
          rig={@rig}
          tool={@tool}
          selected={selected_bone(@rig, @selected_bone)}
        />
        <.viewport rig={@rig} playhead={@playhead} tool={@tool} selected={@selected_bone} />
      </div>

      <.timeline rig={@rig} playhead={@playhead} playing={@playing} pending_pose={@pending_pose} />
      <.export_panel export={@export} />
      <.render_panel rendered={@rendered} frame={@rendered_frame} />
    </div>
    """
  end

  # --- components ----------------------------------------------------------

  attr :rig, :map, default: nil
  attr :tool, :string, required: true
  attr :selected, :map, default: nil

  defp palette(assigns) do
    ~H"""
    <aside class="flex w-56 flex-col gap-4 overflow-y-auto border-r border-base-300 p-3 text-xs">
      <section>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Tools</h2>
        <div class="flex flex-col gap-1">
          <button
            phx-click="select_tool"
            phx-value-tool="bones"
            class={["btn btn-xs justify-start", @tool == "bones" && "btn-primary"]}
          >
            Bones
          </button>
          <button
            phx-click="select_tool"
            phx-value-tool="pose"
            class={["btn btn-xs justify-start", @tool == "pose" && "btn-primary"]}
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

      <section>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Bones</h2>
        <div :if={@rig == nil} class="opacity-60">No rig loaded.</div>
        <ul :if={@rig} class="flex flex-col gap-1">
          <li :for={bone <- Rig.bones(@rig)}>
            <div class={[
              "flex items-center gap-1 rounded px-1 py-0.5",
              @selected && @selected["id"] == bone["id"] && "bg-primary/20"
            ]}>
              <button phx-click="select_bone" phx-value-id={bone["id"]} class="flex-1 text-left">
                {bone["name"] || bone["id"]}
              </button>
              <span class="opacity-50">r{trunc(bone["radius"] || 0)}</span>
              <button phx-click="bone_deleted" phx-value-id={bone["id"]} class="btn btn-ghost btn-xs">
                ×
              </button>
            </div>
          </li>
        </ul>
        <button phx-click="auto_bind" class="btn btn-xs mt-2 w-full" disabled={@rig == nil}>
          Auto-bind mesh
        </button>
      </section>

      <section :if={@rig}>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Bone properties</h2>
        <div :if={@selected}>
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
        </div>
        <div :if={!@selected} class="opacity-60">Select a bone.</div>
      </section>

      <section :if={@rig}>
        <h2 class="mb-2 font-semibold uppercase tracking-wide opacity-70">Bind</h2>
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
      </section>
    </aside>
    """
  end

  attr :rig, :map, default: nil
  attr :playhead, :integer, required: true
  attr :tool, :string, required: true
  attr :selected, :string, default: nil

  defp viewport(assigns) do
    ~H"""
    <section class="relative min-h-0 flex-1 bg-neutral-950">
      <div
        :if={@rig}
        id="viewport"
        phx-hook="LbsPreview"
        data-source-url={~p"/api/rigs/#{@rig["id"]}/source"}
        data-frame={@playhead}
        data-tool={@tool}
        data-selected={@selected || ""}
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

  defp timeline(assigns) do
    ~H"""
    <footer class="border-t border-base-300 px-4 py-2 text-xs">
      <div :if={@rig == nil} class="opacity-60">Timeline appears once a rig is loaded.</div>

      <div :if={@rig} class="flex flex-col gap-2">
        <div class="flex flex-wrap items-center gap-3">
          <button phx-click="toggle_play" class="btn btn-xs">
            <%= if @playing do %>
              Pause
            <% else %>
              Play
            <% end %>
          </button>
          <button phx-click="record_keyframe" class="btn btn-xs btn-primary">Record keyframe</button>
          <button phx-click="delete_keyframe" class="btn btn-xs">Delete keyframe</button>
          <button phx-click="toggle_loop" class={["btn btn-xs", loop?(@rig) && "btn-outline"]}>
            Loop
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

        <div
          id="timeline-track"
          phx-hook="TimelineScrub"
          data-frames={Rig.frame_count(@rig)}
          data-frame={@playhead}
          class="relative h-8 cursor-pointer rounded bg-base-200"
        >
          <div
            class="absolute top-0 h-full w-px bg-primary"
            style={"left: #{playhead_percent(@playhead, Rig.frame_count(@rig))}%"}
          >
          </div>
          <div class="absolute bottom-1 left-0 right-0 h-3">
            <button
              :for={keyframe <- Rig.keyframes(@rig)}
              phx-click="set_playhead"
              phx-value-frame={keyframe["frame"]}
              title={"keyframe #{keyframe["frame"]}"}
              class="absolute h-3 w-1 -translate-x-1/2 bg-accent"
              style={"left: #{playhead_percent(keyframe["frame"], Rig.frame_count(@rig))}%"}
            >
            </button>
          </div>
        </div>
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
