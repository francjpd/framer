defmodule FramerWebWeb.RigController do
  @moduledoc """
  JSON surface for editor rigs over the existing `framer_web` API.

  Mirrors `JobController`: thin, filesystem-first and engine-facing.

    * `GET    /api/rigs`             - list saved rigs
    * `POST   /api/rigs`            - create from a base64 still (or a canvas)
    * `GET    /api/rigs/:id`        - load a rig document
    * `PUT    /api/rigs/:id`        - save a rig document
    * `POST   /api/rigs/:id/render` - render one full-quality frame (PNG)
    * `POST   /api/rigs/:id/export` - submit a chunked deform export
    * `GET    /api/rigs/:id/source` - the source still
    * `GET    /api/rigs/:id/result` - the merged export (download)

  The BEAM never receives pixel data here either: the still is written to disk
  and the engine is handed a path.
  """

  use FramerWebWeb, :controller

  alias FramerWeb.Renderer
  alias FramerWeb.Rig
  alias FramerWeb.RigStore

  def index(conn, _params) do
    json(conn, %{rigs: RigStore.list()})
  end

  def create(conn, params) do
    case build(params) do
      {:ok, rig} ->
        conn
        |> put_status(:created)
        |> json(%{rig: rig})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: error_message(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, rig} <- RigStore.load(id) do
      json(conn, %{rig: rig})
    else
      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: error_message(reason)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    rig =
      params
      |> Map.drop(["id"])
      |> Map.put("id", id)
      |> Map.put_new("schema", Rig.schema())
      |> Map.put_new("version", Rig.version())

    case RigStore.save(rig) do
      {:ok, rig} ->
        json(conn, %{rig: rig})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message(reason)})
    end
  end

  def render(conn, %{"id" => id} = params) do
    frame = params["frame"] || 0

    with {:ok, rig} <- RigStore.load(id),
         {:ok, binary} <- Renderer.render_frame(rig, frame) do
      conn
      |> put_resp_content_type("image/png")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, binary)
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message(reason)})
    end
  end

  def export(conn, %{"id" => id} = params) do
    opts = [
      format: params["format"] || "webm",
      frames: params["frames"],
      fps: params["fps"],
      iterations: params["iterations"]
    ]

    with {:ok, rig} <- RigStore.load(id),
         {:ok, export} <- Renderer.submit_export(rig, opts) do
      conn
      |> put_status(:accepted)
      |> json(%{
        job_id: export.job_id,
        status: "processing",
        output: Path.basename(export.output),
        result_url: ~p"/api/rigs/#{id}/result"
      })
    else
      {:error, reason} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: error_message(reason)})
    end
  end

  def source(conn, %{"id" => id}) do
    case RigStore.source_path(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no source for #{id}"})

      path ->
        conn
        |> put_resp_content_type(MIME.type(path) || "application/octet-stream")
        |> send_file(200, path)
    end
  end

  def result(conn, %{"id" => id}) do
    case RigStore.result_path(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no rendered result for #{id}"})

      path ->
        conn
        |> put_resp_content_type(MIME.type(path) || "application/octet-stream")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{Path.basename(path)}")
        )
        |> send_file(200, path)
    end
  end

  # --- helpers ---

  defp build(%{"source_base64" => encoded} = params) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded) do
      RigStore.create_from_source(binary, binary_param(params, "filename") || "source.png",
        name: binary_param(params, "name")
      )
    else
      :error -> {:error, :invalid_base64}
    end
  end

  defp build(%{"source_base64" => _}), do: {:error, :invalid_base64}

  defp build(%{"width" => width, "height" => height} = params)
       when is_binary(width) and is_binary(height) do
    with {w, ""} <- Integer.parse(width),
         {h, ""} <- Integer.parse(height),
         true <- w > 0 and h > 0 do
      rig =
        Rig.new(w, h, id: UUID.uuid4(), name: binary_param(params, "name") || "Untitled rig")

      RigStore.save(rig)
    else
      _ -> {:error, :invalid_canvas}
    end
  end

  defp build(%{"width" => width, "height" => height} = params)
       when is_integer(width) and is_integer(height) do
    if width > 0 and height > 0 do
      rig =
        Rig.new(width, height,
          id: UUID.uuid4(),
          name: binary_param(params, "name") || "Untitled rig"
        )

      RigStore.save(rig)
    else
      {:error, :invalid_canvas}
    end
  end

  defp build(%{"width" => _, "height" => _}), do: {:error, :invalid_canvas}

  defp build(_params), do: {:error, :missing_source}

  defp binary_param(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp error_message(%{__struct__: _} = error), do: inspect(error)
  defp error_message(:missing_source), do: "a source image or a canvas size is required"
  defp error_message(:enoent), do: "unknown rig"
  defp error_message(:invalid_canvas), do: "width and height must be positive integers"
  defp error_message(:invalid_base64), do: "source_base64 is not valid base64"
  defp error_message(:invalid_id), do: "invalid rig id"
  defp error_message(:escaping_path), do: "the source path escapes the project directory"
  defp error_message({:invalid_rig, reason}), do: reason
  defp error_message({:invalid_json, _}), do: "rig.json is not valid JSON"
  defp error_message(reason), do: inspect(reason)
end
