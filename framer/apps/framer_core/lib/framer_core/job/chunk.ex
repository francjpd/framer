defmodule FramerCore.Job.Chunk do
  @moduledoc """
  Represents a chunk of frames to be processed by a worker.

  Everything needed to run the chunk - operation, paths, frame range and
  options - travels with the chunk so a worker can be given work without any
  further BEAM-side lookup. This is also what makes a chunk portable to a
  remote node.
  """

  defstruct [
    :id,
    :job_id,
    :operation,
    :options,
    :start_frame,
    :end_frame,
    :input_path,
    :output_path,
    :fps,
    :status,
    :worker_id,
    :inserted_at,
    retry_count: 0,
    failed_by: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          job_id: String.t(),
          operation: String.t(),
          options: map(),
          start_frame: non_neg_integer(),
          end_frame: non_neg_integer(),
          input_path: String.t(),
          output_path: String.t(),
          fps: float(),
          status: :pending | :assigned | :processing | :completed | :failed,
          worker_id: String.t() | nil,
          inserted_at: DateTime.t(),
          retry_count: non_neg_integer(),
          failed_by: [String.t()]
        }

  def new(job_id, start_frame, end_frame, input_path, output_path, opts \\ []) do
    %__MODULE__{
      id: UUID.uuid4(),
      job_id: job_id,
      operation: to_string(opts[:operation] || "transcode"),
      options: opts[:options] || %{},
      start_frame: start_frame,
      end_frame: end_frame,
      input_path: input_path,
      output_path: output_path,
      fps: opts[:fps] || 30.0,
      status: :pending,
      worker_id: nil,
      inserted_at: DateTime.utc_now()
    }
  end

  @doc """
  Number of frames in this chunk.
  """
  def frame_count(chunk) do
    chunk.end_frame - chunk.start_frame + 1
  end

  @doc """
  A plain request map for the Python Port worker.
  """
  def to_request(chunk) do
    %{
      "op" => chunk.operation,
      "input" => chunk.input_path,
      "output" => chunk.output_path,
      "start_frame" => chunk.start_frame,
      "end_frame" => chunk.end_frame,
      "fps" => chunk.fps,
      "options" => chunk.options
    }
  end
end
