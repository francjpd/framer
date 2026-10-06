defmodule FramerCore.Operations do
  @moduledoc """
  One-off operations that share the same Port contract as the chunk pipeline.

  `merge` is the finishing step of a chunked job: it concatenates the finished
  chunk files into the requested output. It is deliberately a plain function
  rather than part of the orchestrator so that a future distributed runner can
  choose to merge on whichever node holds the chunks.
  """

  alias FramerCore.PortWorker

  @default_timeout 600_000

  @doc """
  Merge `chunk_paths` into `output_path` through the Python Port worker.
  """
  def merge(output_path, chunk_paths, timeout \\ @default_timeout) do
    paths = Enum.map(chunk_paths, &Path.expand/1)

    request = %{
      "op" => "merge",
      "input" => List.first(paths),
      "output" => output_path,
      "options" => %{"chunks" => paths}
    }

    PortWorker.run_once(request, timeout)
  end

  @doc """
  Merge the completed chunks of a job, ordered by their frame range.
  """
  def merge_job(job, chunks) do
    paths =
      chunks
      |> Enum.sort_by(& &1.start_frame)
      |> Enum.map(& &1.output_path)

    merge(job.output_path, paths)
  end
end
