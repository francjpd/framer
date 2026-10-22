defmodule FramerWeb.Repo.Migrations.CreateHealingCorrections do
  use Ecto.Migration

  @moduledoc """
  The healing corpus: every manual correction the user paints into the
  background layer.

  A row is one correction and it carries the three things a later model would
  be trained on - the content that was painted, the mask it covered and the
  pixels it replaced - plus the rectangle they are cropped to, so the three
  line up.  The corpus is not undo history: it accumulates across projects and
  is kept for good.
  """

  def change do
    create table(:healing_corrections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :rig_id, :string, null: false
      add :project_name, :string

      add :content, :binary, null: false
      add :content_type, :string, null: false, default: "image/png"
      add :mask, :binary, null: false
      add :mask_type, :string, null: false, default: "image/png"
      add :replaced, :binary, null: false
      add :replaced_type, :string, null: false, default: "image/png"

      add :bbox_x, :integer, null: false, default: 0
      add :bbox_y, :integer, null: false, default: 0
      add :bbox_width, :integer, null: false, default: 0
      add :bbox_height, :integer, null: false, default: 0

      add :fade, :integer, null: false, default: 12
      add :brush_radius, :integer, null: false, default: 12
      add :canvas_width, :integer, null: false, default: 0
      add :canvas_height, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:healing_corrections, [:rig_id])
    create index(:healing_corrections, [:inserted_at])
  end
end
