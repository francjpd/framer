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
end
