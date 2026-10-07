defmodule FramerWebWeb.ConnectionsLive do
  @moduledoc """
  Host-side approval surface for the connection contract.

  Lists the pending pairing requests and lets the operator approve or deny each
  one. Only an approved request is issued a session credential and may list or
  read the editor's content.
  """

  use FramerWebWeb, :live_view

  alias FramerWeb.Connections

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(FramerWeb.PubSub, Connections.topic())

    {:ok, assign(socket, :requests, Connections.pending())}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    Connections.approve(id)
    {:noreply, assign(socket, :requests, Connections.pending())}
  end

  def handle_event("deny", %{"id" => id}, socket) do
    Connections.deny(id)
    {:noreply, assign(socket, :requests, Connections.pending())}
  end

  @impl true
  def handle_info(:changed, socket),
    do: {:noreply, assign(socket, :requests, Connections.pending())}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="connections-shell" class="flex h-screen flex-col bg-base-100 text-base-content">
      <header class="flex items-center gap-3 border-b border-base-300 px-4 py-2">
        <h1 class="text-sm font-semibold">Connection requests</h1>
        <a href={~p"/editor"} class="btn btn-xs ml-auto">Open editor</a>
      </header>

      <main class="flex-1 overflow-y-auto p-4 text-sm">
        <div :if={@requests == []} id="no-requests" class="opacity-60">
          No pending connection requests.
        </div>

        <ul :if={@requests != []} id="pending-requests" class="flex flex-col gap-2">
          <li
            :for={request <- @requests}
            id={"request-#{request.id}"}
            class="flex items-center gap-3 rounded border border-base-300 p-2"
          >
            <span class="font-mono text-xs">{request.id}</span>
            <button phx-click="approve" phx-value-id={request.id} class="btn btn-xs btn-success">
              Approve
            </button>
            <button phx-click="deny" phx-value-id={request.id} class="btn btn-xs btn-error">
              Deny
            </button>
          </li>
        </ul>
      </main>
    </div>
    """
  end
end
