defmodule FramerWebWeb.EditorLive do
  @moduledoc """
  Route stub for the rig/bones animation editor (milestones M3-M5).

  The engine half of the feature - the `deform` operation, the rig schema and
  the chunked export - ships first and is exercised entirely through the Port
  contract (paths, frame ranges and JSON options; the BEAM never sees pixels).
  This LiveView is deliberately just the shell: it reserves `/editor`, states
  the contract the real editor will build on, and gives the follow-up task a
  place to grow.  It contains no UI beyond a placeholder.
  """
  use FramerWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Framer Editor")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="editor-shell" class="mx-auto max-w-3xl p-8">
        <h1 class="text-2xl font-semibold">Framer Editor</h1>
        <p id="editor-status" class="mt-2 text-sm">
          Engine ready: the <code>deform</code> operation renders a rig/bones
          puppet warp of a still image over a frame range. The editor itself
          (M3-M5) is a follow-up task.
        </p>
        <ul class="mt-4 list-disc space-y-1 pl-6 text-sm">
          <li>Viewport: source still + rig mesh (paths only)</li>
          <li>Timeline: keyframes over the rig's frame range</li>
          <li>
            Export: submit <code>operation: "deform"</code>
            with <code>options.rig</code>
            through the existing job API
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
