defmodule FramerWeb.Repo do
  @moduledoc """
  The editor's durable store.

  The editor keeps its *documents* filesystem-first (`FramerWeb.RigStore`): a
  project is a directory with the still, the rig document and the materialised
  layers.  The one thing that is *not* a document is the healing corpus - the
  manual corrections the user paints into the background layer, kept so a
  later model can be trained on them.

  The corpus has to outlive the project it was painted in: it accumulates
  across projects and has to survive a restart, and it is training material
  rather than undo history, so it does not belong in a project's directory.
  A database is the right home for it, and SQLite keeps the app
  self-contained - no server to run before the editor works.
  """

  use Ecto.Repo,
    otp_app: :framer_web,
    adapter: Ecto.Adapters.SQLite3
end
