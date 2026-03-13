defmodule FramerCore.Job do
  @moduledoc """
  Represents a video processing job.
  """

  defstruct [
    :id,
    :input_path,
    :output_path,
    :total_frames,
    :chunk_size,
    :status,
    :workers,
    :chunks_assigned,
    :chunks_completed,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          input_path: String.t(),
          output_path: String.t(),
          total_frames: non_neg_integer(),
          chunk_size: non_neg_integer(),
          status: :pending | :processing | :completed | :failed,
          workers: [pid()],
          chunks_assigned: non_neg_integer(),
          chunks_completed: non_neg_integer(),
          inserted_at: DateTime.t()
        }

  def new(input_path, output_path, opts \\ []) do
    %__MODULE__{
      id: UUID.uuid4(),
      input_path: input_path,
      output_path: output_path,
      total_frames: opts[:total_frames] || 0,
      chunk_size: opts[:chunk_size] || 100,
      status: :pending,
      workers: [],
      chunks_assigned: 0,
      chunks_completed: 0,
      inserted_at: DateTime.utc_now()
    }
  end

  @doc """
  Calculate the total number of chunks for this job.
  """
  def total_chunks(%__MODULE__{total_frames: frames, chunk_size: size}) do
    ceil(frames / size)
  end

  @doc """
  Check if job is complete.
  """
  def complete?(%__MODULE__{chunks_assigned: assigned, chunks_completed: completed}) do
    assigned > 0 and assigned == completed
  end
end
