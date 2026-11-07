defmodule FramerWeb.Healing.CorpusTest do
  @moduledoc """
  The healing corpus: the manual corrections kept for later training.

  The corpus is training material, not undo history: it accumulates across
  projects, it lives in the editor's own database, and every correction
  carries the three things a later model would be trained on - the content
  that was painted, the mask it covered and the pixels it replaced.
  """

  use ExUnit.Case, async: false

  alias FramerWeb.Healing
  alias FramerWeb.Healing.Corpus

  test "a correction is stored with its content, mask and replaced region" do
    before = Corpus.count()

    {:ok, correction} =
      Corpus.store(%{
        rig_id: "corpus-test-rig",
        project_name: "Corpus test",
        content: <<137, 80, 78, 71>>,
        mask: <<137, 80, 78, 71>>,
        replaced: <<137, 80, 78, 71>>,
        bbox_x: 4,
        bbox_y: 6,
        bbox_width: 20,
        bbox_height: 10,
        fade: 12,
        brush_radius: 18,
        canvas_width: 64,
        canvas_height: 64
      })

    assert Corpus.count() == before + 1

    assert correction.rig_id == "corpus-test-rig"
    assert correction.content == <<137, 80, 78, 71>>
    assert correction.mask == <<137, 80, 78, 71>>
    assert correction.replaced == <<137, 80, 78, 71>>
    assert correction.bbox_x == 4
    assert correction.bbox_y == 6
    assert correction.bbox_width == 20
    assert correction.bbox_height == 10
    assert correction.fade == 12
    assert correction.brush_radius == 18
    assert correction.inserted_at
  end

  test "the corpus accumulates across projects" do
    before = Corpus.count()

    {:ok, _} = Corpus.store(%{rig_id: "project-a", content: <<1>>, mask: <<2>>, replaced: <<3>>})
    {:ok, _} = Corpus.store(%{rig_id: "project-b", content: <<1>>, mask: <<2>>, replaced: <<3>>})

    assert Corpus.count() == before + 2
  end

  test "a correction without its material is refused" do
    assert {:error, changeset} = Corpus.store(%{rig_id: "incomplete"})
    refute changeset.valid?
  end

  test "an unreadable corrections file is not overwritten" do
    dir = Path.join(System.tmp_dir!(), "framer_corrections_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "corrections.json")
    File.write!(path, "{not json")

    {:ok, correction} =
      Corpus.store(%{rig_id: "keep-me", content: <<1>>, mask: <<2>>, replaced: <<3>>})

    assert {:error, _reason} = Healing.append_correction(correction, path)
    assert File.read!(path) == "{not json"
  end
end
