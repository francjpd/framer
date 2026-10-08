defmodule FramerWebWeb.Auth do
  @moduledoc """
  Plug enforcing the host-approved connection contract on the content API.

  `:host_session` makes sure the browser session holds the host operator's
  long-lived session token, so the host editor's own `<img>`/download calls
  carry it as a cookie. `:require_connection` accepts a token from either the
  `Authorization: Bearer <token>` header (remote CLI clients) or that signed
  session cookie (the host browser), verifies it server-side and halts with
  `401`/`403` when it is missing, unknown or expired.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(action), do: action

  @impl true
  def call(conn, :host_session) do
    token = get_session(conn, :connection_token)

    if valid?(token) do
      assign(conn, :connection_token, token)
    else
      refresh_host_session(conn)
    end
  end

  def call(conn, :require_connection) do
    token = credential(conn)

    case FramerWeb.Connections.verify(token) do
      :ok -> assign(conn, :connection_token, token)
      {:error, reason} -> unauthorized(conn, reason)
    end
  end

  def call(conn, :require_host) do
    if loopback?(conn.remote_ip), do: conn, else: forbidden(conn)
  end

  defp valid?(token) when is_binary(token) do
    match?(:ok, FramerWeb.Connections.verify(token))
  end

  defp valid?(_), do: false

  defp refresh_host_session(conn) do
    if loopback?(conn.remote_ip) do
      token = FramerWeb.Connections.host_session()

      conn
      |> put_session(:connection_token, token)
      |> assign(:connection_token, token)
    else
      delete_session(conn, :connection_token)
    end
  end

  defp loopback?({127, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp credential(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> get_session(conn, :connection_token)
    end
  end

  defp unauthorized(conn, reason) do
    status = if reason == :expired, do: 403, else: 401

    message =
      case reason do
        :expired -> "connection session expired"
        :missing -> "a connection credential is required"
        _ -> "connection is not approved"
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "the host surface is only available locally"}))
    |> halt()
  end
end
