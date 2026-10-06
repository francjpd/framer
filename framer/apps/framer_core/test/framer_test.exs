defmodule FramerCoreTest do
  use ExUnit.Case, async: true

  alias FramerCore.Dispatch
  alias FramerCore.Job
  alias FramerCore.Job.Chunk

  doctest FramerCore

  test "greets the world" do
    assert FramerCore.hello() == :world
  end

  test "a chunk request carries operation, range and options" do
    chunk =
      Chunk.new("job-1", 0, 9, "/in.mp4", "/out.webm",
        operation: "remove-bg",
        options: %{"color" => "0,255,0"},
        fps: 30.0
      )

    request = Chunk.to_request(chunk)

    assert request["op"] == "remove-bg"
    assert request["input"] == "/in.mp4"
    assert request["output"] == "/out.webm"
    assert request["start_frame"] == 0
    assert request["end_frame"] == 9
    assert request["fps"] == 30.0
    assert request["options"] == %{"color" => "0,255,0"}
  end

  test "a job carries the operation and options for its chunks" do
    job =
      Job.new("/in.mp4", "/out.mp4",
        operation: "fps-boost",
        options: %{"target_fps" => 60},
        total_frames: 120
      )

    assert job.operation == "fps-boost"
    assert job.options == %{"target_fps" => 60}
    assert Job.total_chunks(job) == 2
  end

  test "dispatch builds local and remote worker targets" do
    pid = self()
    assert Dispatch.local(pid) == %{kind: :local, worker: pid}

    assert Dispatch.remote(:worker@host, {:global, :player_1}) == %{
             kind: :remote,
             node: :worker@host,
             worker: {:global, :player_1}
           }
  end
end
