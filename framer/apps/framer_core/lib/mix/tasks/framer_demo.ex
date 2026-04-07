defmodule Mix.Tasks.Framer.Demo do
  @moduledoc """
  Demo task to run a video processing job and see the players in action.
  """
  use Mix.Task

  @shortdoc "Runs a demo video processing job"

  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    # Parse workers from args if present (e.g. mix framer.demo --workers 4)
    {opts, _, _} = OptionParser.parse(args, switches: [workers: :integer])
    
    if workers = opts[:workers] do
      old_pid = Process.whereis(FramerCore.Orchestrator)
      FramerCore.Supervisor.set_worker_count(workers)
      wait_for_new_orchestrator(old_pid)
    end

    input = Path.expand("../../../test_assets/redoctopus.mp4", __DIR__)
    output = Path.expand("../../../test_assets/demo_out.mp4", __DIR__)

    # Submit a job - Orchestrator now decides chunk size automatically
    IO.puts("\n🚀 [Demo] Submitting demo job for 100 frames...")
    
    case FramerCore.Orchestrator.submit_job(input, output, [total_frames: 100, target_fps: 60]) do
      {:ok, job_id} ->
        IO.puts("✨ [Demo] Job submitted successfully: #{job_id}\n")
        wait_for_completion(job_id)

      error ->
        IO.puts("❌ [Demo] Failed to submit job: #{inspect(error)}")
    end
  end

  defp wait_for_new_orchestrator(old_pid) do
    new_pid = Process.whereis(FramerCore.Orchestrator)
    if new_pid && new_pid != old_pid do
      :ok
    else
      Process.sleep(100)
      wait_for_new_orchestrator(old_pid)
    end
  end

  defp wait_for_completion(job_id) do
    Process.sleep(1000)
    status = FramerCore.Orchestrator.get_status()

    if status.job && status.job.id == job_id do
      completed = length(status.completed_chunks)
      total = status.total_chunks
      
      cond do
        status.job.status == :failed ->
            IO.puts("\n❌ [Demo] Job FAILED according to Orchestrator status.")
            
        completed < total ->
            # Still working, just keep waiting
            wait_for_completion(job_id)

        true ->
            IO.puts("\n🏁 [Demo] Job COMPLETED! Total chunks processed: #{completed}")
            IO.puts("   Result: #{status.job.output_path}")
            # The chunks are in status.temp_dir and will be cleaned up by Orchestrator on next job/exit
      end
    else
      IO.puts("⚠️ [Demo] Could not find job status for #{job_id}")
    end
  end
end
