defmodule FramerWeb.Healing.Correction do
  @moduledoc """
  One manual correction to the background layer: the healing corpus' row.

  A correction is the material a later model would be trained on, so it keeps
  the three images that describe the fix:

    * `content` - what was painted over the bad area,
    * `mask` - the area the brush covered,
    * `replaced` - the pixels that were there before.

  All three are cropped to the same rectangle (`bbox_*`), so they line up, and
  they are stored the moment the brush is used - never as a later migration,
  because the material cannot be reconstructed afterwards.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @required ~w(rig_id content mask replaced)a

  @fields ~w(
    rig_id project_name
    content content_type mask mask_type replaced replaced_type
    bbox_x bbox_y bbox_width bbox_height
    fade brush_radius canvas_width canvas_height
  )a

  schema "healing_corrections" do
    field(:rig_id, :string)
    field(:project_name, :string)

    field(:content, :binary)
    field(:content_type, :string, default: "image/png")
    field(:mask, :binary)
    field(:mask_type, :string, default: "image/png")
    field(:replaced, :binary)
    field(:replaced_type, :string, default: "image/png")

    field(:bbox_x, :integer, default: 0)
    field(:bbox_y, :integer, default: 0)
    field(:bbox_width, :integer, default: 0)
    field(:bbox_height, :integer, default: 0)

    field(:fade, :integer, default: 12)
    field(:brush_radius, :integer, default: 12)
    field(:canvas_width, :integer, default: 0)
    field(:canvas_height, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @doc "The changeset that stores a correction."
  def changeset(correction, attrs) do
    correction
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
