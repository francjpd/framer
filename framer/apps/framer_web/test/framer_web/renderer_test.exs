defmodule FramerWeb.RendererTest do
  use ExUnit.Case, async: true

  alias FramerWeb.Renderer

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
end
