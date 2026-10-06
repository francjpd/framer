defmodule FramerWebWeb.JobControllerTest do
  use FramerWebWeb.ConnCase, async: false

  describe "GET /api/status" do
    test "returns the current orchestrator status", %{conn: conn} do
      conn = get(conn, ~p"/api/status")

      body = json_response(conn, 200)
      assert Map.has_key?(body, "job")
      assert Map.has_key?(body, "total_chunks")
      assert Map.has_key?(body, "completed_chunks")
      assert Map.has_key?(body, "failed_chunks")
    end
  end

  describe "GET /api/jobs/:id" do
    test "returns 404 for an unknown job", %{conn: conn} do
      conn = get(conn, ~p"/api/jobs/does-not-exist")

      assert %{"error" => "unknown job"} = json_response(conn, 404)
    end
  end

  describe "POST /api/jobs" do
    test "requires operation, input and output", %{conn: conn} do
      conn = post(conn, ~p"/api/jobs", %{})

      assert %{"error" => "operation, input and output are required"} =
               json_response(conn, 400)
    end
  end
end
