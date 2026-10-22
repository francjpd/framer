defmodule FramerWeb.Healing do
  @moduledoc """
  The healing brush: the editor's hand-painted correction to the background
  layer.

  The automatic patch reconstructs the ground the character uncovers from the
  surrounding background and feathers it into the untouched plate.  When that
  is not good enough, the user repairs the area by hand with this brush: they
  paint over the bad area and the surrounding background is painted over it,
  with the very same feathered falloff the patch uses - so a hand-painted
  correction merges into the untouched background exactly like the automatic
  one, and never as a hard-edged blob.

  Every correction is also *material*: the content that was painted, the mask
  it covered and the pixels it replaced.  Those three are stored in the
  editor's durable store (`FramerWeb.Healing.Corpus`) the moment the
  correction lands, so the corpus accumulates across projects and can later
  train a model to do the reconstruction itself.  Storing is part of using the
  brush, not a later migration: the material is nearly free while it is being
  painted and impossible to reconstruct afterwards.
  """

  alias FramerWeb.Healing.Corpus

  # The three artefacts the engine writes for every correction.
  @content_file "content.png"
  @mask_file "mask.png"
  @replaced_file "replaced.png"
  @meta_file "correction.json"

  @doc """
  Store the correction the engine just wrote.

  `artifacts_dir` holds the three images and the sidecar that records the
  rectangle they are cropped to; `meta` carries what only the editor knows -
  the project the correction was painted in and the canvas it was painted on.

  Returns `{:ok, correction}` or `{:error, reason}`.
  """
  def store_correction(artifacts_dir, meta \\ %{}) do
    with {:ok, content} <- read_artifact(artifacts_dir, @content_file),
         {:ok, mask} <- read_artifact(artifacts_dir, @mask_file),
         {:ok, replaced} <- read_artifact(artifacts_dir, @replaced_file),
         {:ok, sidecar} <- read_sidecar(artifacts_dir) do
      bbox = sidecar["bbox"] || %{}

      Corpus.store(%{
        rig_id: meta[:rig_id],
        project_name: meta[:project_name],
        content: content,
        mask: mask,
        replaced: replaced,
        bbox_x: bbox["x"] || 0,
        bbox_y: bbox["y"] || 0,
        bbox_width: bbox["width"] || 0,
        bbox_height: bbox["height"] || 0,
        fade: sidecar["fade"] || meta[:fade] || 0,
        brush_radius: sidecar["radius"] || meta[:radius] || 0,
        canvas_width: meta[:canvas_width] || 0,
        canvas_height: meta[:canvas_height] || 0
      })
    end
  end

  @doc """
  A short description of a stored correction.

  The images themselves stay in the corpus: a summary is what the editor
  shows, and it never carries pixels.
  """
  def summarize(correction) do
    %{
      id: correction.id,
      rig_id: correction.rig_id,
      project_name: correction.project_name,
      bbox: %{
        x: correction.bbox_x,
        y: correction.bbox_y,
        width: correction.bbox_width,
        height: correction.bbox_height
      },
      fade: correction.fade,
      inserted_at: correction.inserted_at
    }
  end

  defp read_artifact(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, "the correction's #{name} could not be read: #{reason}"}
    end
  end

  defp read_sidecar(dir) do
    case File.read(Path.join(dir, @meta_file)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, meta} when is_map(meta) -> {:ok, meta}
          _ -> {:ok, %{}}
        end

      {:error, _reason} ->
        {:ok, %{}}
    end
  end
end
