defmodule FramerWeb.Healing.Corpus do
  @moduledoc """
  The healing corpus: the manual corrections the user paints into the
  background layer, kept for later training.

  The corpus is *not* undo history and it is *not* part of a project's
  directory: it is training material, it accumulates across projects, and it
  has to survive a restart - so it lives in the editor's database
  (`FramerWeb.Repo`).

  Storing is part of using the brush: every correction is stored the first
  time it is applied, with the content that was painted, the mask it covered
  and the pixels it replaced.  The material cannot be reconstructed
  afterwards, so there is no opt-in and no migration - the corpus is simply
  there from the first correction.
  """

  import Ecto.Query

  require Logger

  alias FramerWeb.Healing.Correction
  alias FramerWeb.Repo

  @doc """
  Store one correction.

  `attrs` carries the three images - `:content`, `:mask` and `:replaced` - and
  the rectangle they are cropped to.  Returns `{:ok, correction}` or
  `{:error, changeset}`.
  """
  def store(attrs) do
    %Correction{}
    |> Correction.changeset(attrs)
    |> Repo.insert()
  rescue
    error ->
      # A store that is not reachable must not take the editor down with it:
      # the correction is applied to the plate either way, and the failure is
      # reported in words.
      Logger.error("could not store the correction: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  @doc "How many corrections the corpus holds."
  def count do
    Repo.aggregate(Correction, :count)
  rescue
    _error -> 0
  end

  @doc "How many corrections were painted into `rig_id`."
  def count_for_rig(rig_id) when is_binary(rig_id) do
    Repo.aggregate(from(c in Correction, where: c.rig_id == ^rig_id), :count)
  rescue
    _error -> 0
  end

  @doc """
  The corpus, newest first.

  The images are not loaded: a corpus is a pile of training material, and
  listing it must not pull megabytes of pixels into the BEAM.
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Correction
    |> order_by([c], desc: c.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "One correction with its images, or nil."
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Correction, uuid)
      :error -> nil
    end
  end
end
