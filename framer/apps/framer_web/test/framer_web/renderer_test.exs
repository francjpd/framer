defmodule FramerWeb.RendererTest do
  use ExUnit.Case, async: true

  alias FramerWeb.Renderer
  alias FramerWeb.Rig
  alias FramerWeb.RigStore
  alias FramerWebWeb.Fixtures

  @state %{completed_chunks: [%{}], failed_chunks: [], total_chunks: 1}
  @output "/projects/abc/output.webm"

  test "a merged export is reported as completed with a usable output" do
    event = Renderer.completion_event("job-1", {:ok, @output}, @output, @state)

    assert event.status == :completed
    assert event.result == {:ok, @output}
    assert event.error == nil
    assert event.output == @output
  end

  test "a failed merge is reported as failed, never as completed" do
    event = Renderer.completion_event("job-1", {:error, "FFmpeg merge failed"}, @output, @state)

    assert event.status == :failed
    assert event.error =~ "FFmpeg merge failed"
    refute event.status == :completed
  end

  test "a failed job says why, in words" do
    message = Renderer.job_failure_message(%{failed_chunks: [%{}, %{}], total_chunks: 6})

    assert message == "2 of 6 chunks could not be rendered"
    refute message =~ ":"
  end

  test "a failure reason reaches the user as words, never as a term" do
    # The engine's own message is already a sentence.
    assert Renderer.failure_message("the engine could not read the layer") ==
             "the engine could not read the layer"

    # The app's own reasons are translated.
    assert Renderer.failure_message(:missing_source) =~ "source image"
    assert Renderer.failure_message(:job_in_progress) =~ "already running"

    # A worker's failure is a sentence, not the term it carries.
    worker_failure = Renderer.failure_message({:worker_exit, 1})
    assert worker_failure =~ "render engine"
    refute worker_failure =~ ":"

    task_failure = Renderer.failure_message({:task_down, :killed})
    assert task_failure =~ "render engine"
    refute task_failure =~ ":"
  end

  test "a patch the engine cannot build is reported as a failure" do
    {:ok, project} = RigStore.create_from_source(Fixtures.png_with_subject(32, 32), "subject.png")

    # A split rig with a skeleton and a feather: the engine builds the patch
    # and writes it beside the still.
    rig =
      Fixtures.simple_rig(32)
      |> Map.put("id", project["id"])
      |> Rig.enable_split()

    _saved = RigStore.save(rig)
    assert {:ok, patch} = Renderer.build_patch(rig)
    assert File.exists?(patch)

    # Without the background layer there is no plate to heal against, so the
    # engine builds no patch - and the renderer must not answer with the file
    # that is left over, which is in no render.
    without_plate = Rig.remove_layer(rig, "background")
    _saved = RigStore.save(without_plate)

    assert Renderer.build_patch(without_plate) == {:error, :patch_not_materialised}
  end
end
