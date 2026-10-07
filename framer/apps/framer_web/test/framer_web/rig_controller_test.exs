defmodule FramerWebWeb.RigControllerTest do
  use FramerWebWeb.ConnCase, async: false

  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  setup_all do
    original = Application.get_env(:framer_web, :projects_dir)
    root = Path.join(System.tmp_dir!(), "framer_controller_#{System.unique_integer([:positive])}")
    Application.put_env(:framer_web, :projects_dir, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:framer_web, :projects_dir, original)
    end)

    {:ok, root: root}
  end

  describe "GET /api/rigs" do
    test "lists saved rigs", %{conn: conn} do
      {:ok, rig} = RigStore.save(Fixtures.simple_rig(32))

      body = conn |> get(~p"/api/rigs") |> json_response(200)
      assert Enum.any?(body["rigs"], &(&1["id"] == rig["id"]))
    end
  end

  describe "POST /api/rigs" do
    test "creates a rig from a base64 still and derives the canvas", %{conn: conn} do
      payload = %{
        "name" => "Uploaded",
        "filename" => "subject.png",
        "source_base64" => Base.encode64(Fixtures.png(24, 18))
      }

      body = conn |> post(~p"/api/rigs", payload) |> json_response(201)
      rig = body["rig"]

      assert rig["name"] == "Uploaded"
      assert rig["canvas"] == %{"width" => 24, "height" => 18}
      assert {:ok, loaded} = RigStore.load(rig["id"])
      assert loaded["source"]["path"] == RigStore.source_path(rig["id"])
    end

    test "creates a rig from an explicit canvas", %{conn: conn} do
      body = conn |> post(~p"/api/rigs", %{"width" => 100, "height" => 50}) |> json_response(201)
      assert body["rig"]["canvas"] == %{"width" => 100, "height" => 50}
    end

    test "rejects bad input", %{conn: conn} do
      assert %{"error" => message} =
               conn |> post(~p"/api/rigs", %{"source_base64" => "!!!"}) |> json_response(400)

      assert message =~ "base64"

      assert %{"error" => message} =
               conn |> post(~p"/api/rigs", %{}) |> json_response(400)

      assert message =~ "source image"
    end

    test "returns 400, not 500, for non-string base64 and canvas values", %{conn: conn} do
      assert %{"error" => message} =
               conn |> post(~p"/api/rigs", %{"source_base64" => 123}) |> json_response(400)

      assert message =~ "base64"

      assert %{"error" => message} =
               conn
               |> post(~p"/api/rigs", %{"width" => %{"a" => 1}, "height" => [1]})
               |> json_response(400)

      assert message =~ "positive integers"
    end

    test "tolerates non-string filename and name without breaking the listing", %{conn: conn} do
      payload = %{
        "source_base64" => Base.encode64(Fixtures.png(12, 12)),
        "filename" => %{"nested" => true},
        "name" => %{"nested" => true}
      }

      body = conn |> post(~p"/api/rigs", payload) |> json_response(201)
      assert is_binary(body["rig"]["name"])

      listing = conn |> get(~p"/api/rigs") |> json_response(200)
      listed = Enum.find(listing["rigs"], &(&1["id"] == body["rig"]["id"]))
      assert is_binary(listed["name"])
    end
  end

  describe "GET/PUT /api/rigs/:id" do
    test "loads and saves a rig document", %{conn: conn} do
      {:ok, rig} = RigStore.save(Fixtures.simple_rig(40))
      id = rig["id"]

      assert %{"rig" => loaded} = conn |> get(~p"/api/rigs/#{id}") |> json_response(200)
      assert loaded["id"] == id

      updated = %{loaded | "name" => "Renamed"}
      assert %{"rig" => saved} = conn |> put(~p"/api/rigs/#{id}", updated) |> json_response(200)
      assert saved["name"] == "Renamed"
      assert {:ok, from_disk} = RigStore.load(id)
      assert from_disk["name"] == "Renamed"
    end

    test "returns 404 for an unknown rig", %{conn: conn} do
      assert %{"error" => "unknown rig"} =
               conn |> get(~p"/api/rigs/nope") |> json_response(404)
    end

    test "rejects a non-string name rather than persisting it", %{conn: conn} do
      {:ok, rig} = RigStore.save(Fixtures.simple_rig(40))
      id = rig["id"]

      assert %{"error" => message} =
               conn
               |> put(~p"/api/rigs/#{id}", %{rig | "name" => %{"nested" => true}})
               |> json_response(422)

      assert message =~ "name"
      assert {:ok, from_disk} = RigStore.load(id)
      assert from_disk["name"] == rig["name"]
    end
  end

  describe "GET /api/rigs/:id/source" do
    test "serves the still", %{conn: conn} do
      {:ok, rig} = RigStore.create_from_source(Fixtures.png(8, 8), "s.png")
      response = conn |> get(~p"/api/rigs/#{rig["id"]}/source") |> response(200)
      assert response == Fixtures.png(8, 8)
    end

    test "404s when there is no source", %{conn: conn} do
      {:ok, rig} = RigStore.save(FramerWeb.Rig.new(8, 8))

      assert %{"error" => message} =
               conn |> get(~p"/api/rigs/#{rig["id"]}/source") |> json_response(404)

      assert message =~ "no source"
    end

    test "does not serve files outside the projects root", %{conn: conn, root: root} do
      secret_dir = Path.join(Path.dirname(root), Path.basename(root) <> "_secret")
      File.mkdir_p!(secret_dir)
      File.write!(Path.join(secret_dir, "source.png"), "top secret")
      on_exit(fn -> File.rm_rf(secret_dir) end)

      traversal = "..%2F" <> Path.basename(secret_dir)
      body = conn |> get("/api/rigs/#{traversal}/source") |> response(404)
      refute String.contains?(body, "top secret")
    end
  end

  describe "GET /api/rigs/:id/result" do
    test "404s until an export exists", %{conn: conn} do
      {:ok, rig} = RigStore.save(Fixtures.simple_rig(8))

      assert %{"error" => message} =
               conn |> get(~p"/api/rigs/#{rig["id"]}/result") |> json_response(404)

      assert message =~ "no rendered result"
    end

    test "does not serve results outside the projects root", %{conn: conn, root: root} do
      secret_dir = Path.join(Path.dirname(root), Path.basename(root) <> "_result_secret")
      File.mkdir_p!(secret_dir)
      File.write!(Path.join(secret_dir, "output.webm"), "top secret")
      on_exit(fn -> File.rm_rf(secret_dir) end)

      traversal = "..%2F" <> Path.basename(secret_dir)
      body = conn |> get("/api/rigs/#{traversal}/result") |> response(404)
      refute String.contains?(body, "top secret")
    end
  end
end
