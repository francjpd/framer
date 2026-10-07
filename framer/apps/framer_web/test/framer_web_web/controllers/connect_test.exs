defmodule FramerWebWeb.ConnectTest do
  @moduledoc """
  The host-approved connection contract: no content is served to an unapproved
  caller, presenting the pairing id only creates a pending request, and only an
  approved session - verified server side and expiring - may read content.
  """

  use FramerWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias FramerWeb.Connections
  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  @client {203, 0, 113, 5}

  setup_all do
    original = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_connect_#{System.unique_integer([:positive])}")
    Application.put_env(:framer_web, :projects_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:framer_web, :projects_dir, original)
    end)

    :ok
  end

  defp remote(conn), do: %{conn | remote_ip: @client}

  defp protect(conn, token) when is_binary(token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp protect(conn, _), do: conn

  test "unapproved requests to every content endpoint are rejected with no content without a token",
       %{
         conn: conn
       } do
    {:ok, rig} = RigStore.create_from_source(Fixtures.png(8, 8), "s.png")
    id = rig["id"]

    checks = [
      get(remote(conn), ~p"/api/rigs"),
      post(remote(conn), ~p"/api/rigs", %{"width" => 8, "height" => 8}),
      get(remote(conn), ~p"/api/rigs/#{id}"),
      put(remote(conn), ~p"/api/rigs/#{id}", rig),
      post(remote(conn), ~p"/api/rigs/#{id}/render", %{"frame" => 0}),
      post(remote(conn), ~p"/api/rigs/#{id}/export", %{"format" => "webm"}),
      get(remote(conn), ~p"/api/rigs/#{id}/source"),
      get(remote(conn), ~p"/api/rigs/#{id}/result")
    ]

    for %{status: status} <- checks do
      assert status in [401, 403], "expected 401/403, got #{status}"
    end
  end

  test "the pairing id is validated and only creates a pending request", %{conn: conn} do
    assert %{"error" => _} =
             conn
             |> remote()
             |> post(~p"/api/connect", %{"id" => "not-the-pairing-id"})
             |> json_response(403)

    assert %{"request_id" => request_id, "status" => "pending"} =
             conn
             |> remote()
             |> post(~p"/api/connect", %{"id" => Connections.pairing_id()})
             |> json_response(202)

    assert %{"status" => "pending"} =
             conn
             |> remote()
             |> get(~p"/api/connect/#{request_id}")
             |> json_response(202)

    assert %{"error" => _} =
             conn
             |> remote()
             |> protect(request_id)
             |> get(~p"/api/rigs")
             |> json_response(401)
  end

  test "an approved request receives a session that can read content", %{conn: conn} do
    {:ok, rig} = RigStore.create_from_source(Fixtures.png(8, 8), "s.png")

    request_id = request(conn)

    token =
      case Connections.approve(request_id) do
        {:ok, token, _expires_at} -> token
      end

    assert %{"status" => "approved", "token" => ^token} =
             conn
             |> remote()
             |> get(~p"/api/connect/#{request_id}")
             |> json_response(200)

    body =
      conn
      |> remote()
      |> protect(token)
      |> get(~p"/api/rigs/#{rig["id"]}/source")
      |> response(200)

    assert body == Fixtures.png(8, 8)
  end

  test "a denied request is rejected", %{conn: conn} do
    request_id = request(conn)
    assert :ok = Connections.deny(request_id)

    assert %{"status" => "denied"} =
             conn
             |> remote()
             |> get(~p"/api/connect/#{request_id}")
             |> json_response(403)
  end

  test "an unknown or expired credential is rejected", %{conn: conn} do
    assert %{"error" => _} =
             conn
             |> remote()
             |> protect("made-up-token")
             |> get(~p"/api/rigs")
             |> json_response(401)

    expired = Connections.issue_session(-1)

    assert %{"error" => _} =
             conn
             |> remote()
             |> protect(expired)
             |> get(~p"/api/rigs")
             |> json_response(403)
  end

  test "the host operator's editor connection is authorized", %{conn: conn} do
    {:ok, rig} = RigStore.create_from_source(Fixtures.png(8, 8), "s.png")

    assert %{"rigs" => rigs} = conn |> get(~p"/api/rigs") |> json_response(200)
    assert Enum.any?(rigs, &(&1["id"] == rig["id"]))
  end

  test "the host approval surface lists and approves pending requests", %{conn: conn} do
    request_id = request(conn)

    {:ok, view, _html} = live(conn, ~p"/connections")
    assert has_element?(view, "#request-#{request_id}")

    render_click(view, "approve", %{"id" => request_id})
    refute has_element?(view, "#request-#{request_id}")
    assert {:approved, _token, _expires_at} = Connections.status(request_id)
  end

  defp request(conn) do
    %{"request_id" => request_id} =
      conn
      |> remote()
      |> post(~p"/api/connect", %{"id" => Connections.pairing_id()})
      |> json_response(202)

    request_id
  end
end
