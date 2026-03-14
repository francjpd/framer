defmodule Mix.Tasks.Framer.Demo do
  @moduledoc """
  Demo task to run a video processing job and see the players in action.
  """
  use Mix.Task

  @shortdoc "Runs a demo video processing job"

  def run(_args) do
    # Start the application
    Mix.Task.run("app.start")

    input = "/home/francjpd/projects/framer/test_assets/redoctopus.mp4"
    output = "/home/francjpd/projects/framer/test_assets/demo_out.mp4"

    # Submit a job for 100 frames with 20-frame chunks (5 chunks total)
    # This should exercise all 3 players (cpu-1, cpu-2, gpu-1)
    IO.puts("\n🚀 [Demo] Submitting demo job for 100 frames (5 chunks of 20 frames each)...")
    
    case FramerCore.Orchestrator.submit_job(input, output, [total_frames: 100, chunk_size: 20]) do
      {:ok, job_id} ->
        IO.puts("✨ [Demo] Job submitted successfully: #{job_id}\n")
        wait_for_completion(job_id)

      error ->
        IO.puts("❌ [Demo] Failed to submit job: #{inspect(error)}")
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
      end
    else
      IO.puts("⚠️ [Demo] Could not find job status for #{job_id}")
    end
  end
end
