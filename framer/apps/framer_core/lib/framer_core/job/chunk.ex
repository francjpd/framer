defmodule FramerCore.Job.Chunk do
  @moduledoc """
  Represents a chunk of frames to be processed.
  """

  defstruct [
    :id,
    :job_id,
    :start_frame,
    :end_frame,
    :status,
    :worker_id,
    :result_path,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          job_id: String.t(),
          start_frame: non_neg_integer(),
          end_frame: non_neg_integer(),
          status: :pending | :assigned | :processing | :completed | :failed,
          worker_id: String.t() | nil,
          result_path: String.t() | nil,
          inserted_at: DateTime.t()
        }

  def new(job_id, start_frame, end_frame) do
    %__MODULE__{
      id: UUID.uuid4(),
      job_id: job_id,
      start_frame: start_frame,
      end_frame: end_frame,
      status: :pending,
      worker_id: nil,
      result_path: nil,
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
