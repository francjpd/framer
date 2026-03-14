defmodule FramerCore.Job.Chunk do
  @moduledoc """
  Represents a chunk of frames to be processed.
  """

  defstruct [
    :id,
    :job_id,
    :start_frame,
    :end_frame,
    :input_path,
    :output_path,
    :fps,
    :target_fps,
    :status,
    :worker_id,
    :inserted_at,
    retry_count: 0,
    failed_by: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          job_id: String.t(),
          start_frame: non_neg_integer(),
          end_frame: non_neg_integer(),
          input_path: String.t(),
          output_path: String.t(),
          fps: float(),
          target_fps: integer() | nil,
          status: :pending | :assigned | :processing | :completed | :failed,
          worker_id: String.t() | nil,
          inserted_at: DateTime.t(),
          retry_count: non_neg_integer(),
          failed_by: [String.t()]
        }

  def new(job_id, start_frame, end_frame, input_path, output_path) do
    %__MODULE__{
      id: UUID.uuid4(),
      job_id: job_id,
      start_frame: start_frame,
      end_frame: end_frame,
      input_path: input_path,
      output_path: output_path,
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
end
