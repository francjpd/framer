defmodule FramerWebWeb.JobController do
  @moduledoc """
  Minimal JSON surface over the `FramerCore.Orchestrator`.

  This is intentionally small: it proves the Phoenix app is wired to the real
  chunk orchestrator and gives the next task (the full control UI) a stable
  place to grow. It is not the control UI.
  """
  use FramerWebWeb, :controller

  alias FramerCore.Orchestrator
  alias FramerCore.PortWorker

  @doc "GET /api/status - current orchestrator/job status."
  def status(conn, _params) do
    json(conn, serialize(Orchestrator.get_status()))
  end

  @doc "GET /api/jobs/:id - status for a specific job."
  def show(conn, %{"id" => id}) do
    state = Orchestrator.get_status()

    if state.job && state.job.id == id do
      json(conn, serialize(state))
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "unknown job", id: id})
    end
  end

  @doc "POST /api/jobs - submit a job to the orchestrator."
  def create(conn, params) do
    operation = params["operation"]
    input = params["input"]
    output = params["output"]
    options = params["options"] || %{}

    cond do
      is_nil(operation) or is_nil(input) or is_nil(output) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "operation, input and output are required"})

      true ->
        submit(conn, operation, input, output, options, params)
    end
  end

  defp submit(conn, operation, input, output, options, params) do
    case resolve_video(input) do
      {:ok, info} ->
        total_frames = params["total_frames"] || info["total_frames"]
        fps = params["fps"] || info["fps"]

        request = [
          operation: operation,
          options: options,
          total_frames: total_frames,
          fps: fps
        ]

        case Orchestrator.submit_job(input, output, request) do
          {:ok, job_id} ->
            conn |> put_status(:accepted) |> json(%{job_id: job_id, status: "processing"})

          {:error, reason} ->
            conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "could not read video: #{inspect(reason)}"})
    end
  end

  defp resolve_video(input) do
    PortWorker.run_once(%{"op" => "info", "input" => input})
  end

  defp serialize(%{job: nil} = state) do
    %{
      job: nil,
      total_chunks: state.total_chunks,
      completed_chunks: 0,
      failed_chunks: 0,
      active_chunks: 0,
      progress: 0.0
    }
  end

  defp serialize(state) do
    job = state.job
    completed = length(state.completed_chunks)
    failed = length(state.failed_chunks)
    done = completed + failed

    progress =
      if state.total_chunks > 0 do
        Float.round(done / state.total_chunks * 100, 1)
      else
        0.0
      end

    %{
      job: %{
        id: job.id,
        operation: job.operation,
        status: job.status,
        input: job.input_path,
        output: job.output_path,
        total_frames: job.total_frames
      },
      total_chunks: state.total_chunks,
      completed_chunks: completed,
      failed_chunks: failed,
      active_chunks: map_size(state.active_chunks),
      progress: progress
    }
  end
end
