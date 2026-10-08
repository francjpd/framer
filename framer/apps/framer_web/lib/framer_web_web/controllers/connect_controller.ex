defmodule FramerWebWeb.ConnectController do
  @moduledoc """
  Two-way pairing handshake for the editor's content API.

    * `POST /api/connect` - a client presents the host's pairing id; this
      creates a *pending* request and returns its id. Presenting the id never
      grants access.
    * `GET  /api/connect/:request_id` - the client polls; while pending it gets
      `202`, on approval it receives the session token, on denial `403`.
  """

  use FramerWebWeb, :controller

  alias FramerWeb.Connections

  def create(conn, params) do
    pairing_id = params["id"] || params["pairing_id"]

    case Connections.request(pairing_id, %{agent: params["agent"]}) do
      {:ok, request_id} ->
        conn
        |> put_status(:accepted)
        |> json(%{request_id: request_id, status: "pending"})

      {:error, :invalid_pairing_id} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "invalid pairing id"})
    end
  end

  def show(conn, %{"request_id" => request_id}) do
    case Connections.status(request_id) do
      {:pending, id} ->
        conn
        |> put_status(:accepted)
        |> json(%{request_id: id, status: "pending"})

      {:approved, token, expires_at} ->
        json(conn, %{
          request_id: request_id,
          status: "approved",
          token: token,
          expires_at: expires_at
        })

      :denied ->
        conn
        |> put_status(:forbidden)
        |> json(%{request_id: request_id, status: "denied"})

      {:error, :unknown_request} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "unknown connection request"})
    end
  end
end
