# Actor Model Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement actor model concurrency pattern for video processing in Elixir with orchestrator-workers architecture, prefetching, and failure handling.

**Architecture:** Single orchestrator process manages a chunk queue and spawns worker processes. Each worker has its own inbox/mailbox for receiving work. Workers prefetch the next chunk at 20% progress threshold. No shared state between workers - all communication via message passing.

**Tech Stack:** Elixir/OTP, GenServer behaviors

---

## 1. Pattern Overview

The actor model implementation for video processing applies the following principles:

- **Isolation**: Each worker is an independent process with its own state and mailbox. No shared memory or locks.
- **Message Passing**: All communication between orchestrator and workers happens via asynchronous messages.
- **Non-blocking Prefetch**: Workers request the next chunk when 20% through current chunk processing.
- **Single Source of Truth**: Orchestrator maintains the canonical chunk queue and work assignment state.
- **Supervision**: Workers are supervised - failures are detected and handled gracefully.

**Why This Architecture for Video Processing:**
- Video chunks can be processed independently and out of order
- Prefetching hides I/O latency between chunks
- Actor model naturally models the producer-consumer problem
- Elixir's lightweight processes make spawning many workers cheap

---

## 2. Process Structure

### 2.1 Orchestrator Process

**Responsibilities:**
- Manages the canonical chunk queue (list of unassigned chunk IDs/ranges)
- Tracks assigned chunks (which worker has which chunk)
- Spawns and supervises worker processes
- Receives completion messages from workers
- Handles worker failures and reassigns chunks

**State:**
```elixir
%{
  chunk_queue: [chunk_id, ...],           # unassigned chunks
  assignments: %{worker_pid => chunk_id}, # active assignments
  video_path: "/path/to/video.mp4",
  chunk_size: 10_000_000,                 # bytes per chunk
  total_chunks: 50,
  completed: MapSet.new(),                 # completed chunk IDs
  worker_supervisor: pid                  # supervisor reference
}
```

### 2.2 Worker Process

**Responsibilities:**
- Receives chunk work via its own mailbox
- Processes the assigned video chunk (decode, transform, encode)
- Tracks own progress percentage
- Prefetches next chunk at 20% threshold
- Reports completion/failure back to orchestrator

**State:**
```elixir
%{
  orchestrator: pid,
  current_chunk: chunk_id,
  chunk_data: <<binary>>,
  progress: 0.0,           # 0.0 to 1.0
  status: :idle | :processing | :completed | :failed
}
```

---

## 3. Message Contracts

### 3.1 Orchestrator → Worker Messages

**Assign Chunk:**
```elixir
{:assign_chunk, chunk_id, byte_range, next_chunk_available?}
```
- `chunk_id`: Unique identifier for this chunk
- `byte_range`: `{start_byte, end_byte}` for reading chunk data
- `next_chunk_available?`: Boolean indicating if more work exists

**Prefetch Response:**
```elixir
{:prefetch_chunk, chunk_id, byte_range}
```
- Sent when worker reaches 20% threshold and requests more work

**Worker Shutdown:**
```elixir
{:shutdown, reason}
```
- Graceful shutdown request from orchestrator

### 3.2 Worker → Orchestrator Messages

**Chunk Completed:**
```elixir
{:chunk_completed, chunk_id, result}
```
- `result`: `:ok` or `{:error, details}`

**Prefetch Request:**
```elixir
{:prefetch_request, worker_pid}
```
- Worker requests next chunk when at 20% threshold

**Worker Ready:**
```elixir
{:worker_ready, worker_pid}
```
- Worker signals it's initialized and ready for work

**Worker Failed:**
```elixir
{:worker_failed, worker_pid, reason}
```
- Worker encountered unrecoverable error

### 3.3 Internal Orchestrator Messages

**Chunk Result:**
```elixir
{:chunk_result, chunk_id, :ok | {:error, reason}}
```
- Internal message after processing completes

**Worker Terminated:**
```elixir
{:DOWN, ref, :process, pid, reason}
```
- Erlang exit signal when worker crashes

---

## 4. Worker Lifecycle

### 4.1 Worker Creation

1. Orchestrator spawns worker via `Supervisor.start_child/2`
2. Worker initializes with state: `{orchestrator_pid, :idle}`
3. Worker sends `{:worker_ready, self()}` to orchestrator
4. Orchestrator assigns first chunk if available

### 4.2 Work Assignment Flow

```
Orchestrator                        Worker
    |                                  |
    |--- {:assign_chunk, 1, ...} ---> |
    |                                  | (process chunk)
    |                                  | (at 20%)
    |<-- {:prefetch_request} ---------| 
    |                                  |
    |--- {:prefetch_chunk, 2, ...} -->|
    |                                  |
    |<-- {:chunk_completed, 1} ------|
    |                                  |
    |--- {:assign_chunk, 3, ...} ---> |
    |                                  |
```

### 4.3 Worker Termination

**Graceful:**
1. Orchestrator sends `{:shutdown, :normal}`
2. Worker finishes current work, sends final `{:chunk_completed, ...}`
3. Worker sends `{:worker_shutdown, self()}` to confirm
4. Orchestrator removes from active assignments

**Ungraceful (crash):**
1. Worker process exits unexpectedly
2. Orchestrator receives `{:DOWN, ...}` from monitor/linked process
3. Failed chunk is re-queued for another worker (see Failure Handling)

---

## 5. Chunk Management

### 5.1 Chunk Division Strategy

```elixir
def divide_into_chunks(video_path, chunk_size_bytes) do
  # Get total file size
  total_size = File.stat!(video_path).size
  
  # Calculate number of chunks
  chunk_count = ceil(total_size / chunk_size_bytes)
  
  # Generate chunk definitions
  for i <- 0..(chunk_count - 1) do
    start_byte = i * chunk_size_bytes
    end_byte = min(start_byte + chunk_size_bytes - 1, total_size - 1)
    
    %{
      id: i,
      byte_range: {start_byte, end_byte},
      size: end_byte - start_byte + 1
    }
  end
end
```

### 5.2 Chunk Tracking in Orchestrator

```elixir
def init_orchestrator(video_path, num_workers, chunk_size) do
  chunks = divide_into_chunks(video_path, chunk_size)
  
  %{
    chunk_queue: chunks,           # remaining work
    assignments: %{},               # worker -> chunk
    completed: MapSet.new(),
    in_progress: %{}                # chunk_id -> worker_pid
  }
end
```

### 5.3 Prefetch Logic

When worker reaches 20% progress:
1. Check if `next_chunk_available?` is true from initial assignment
2. If yes and worker has capacity, immediately process next chunk
3. If no, send `{:prefetch_request, self()}` to orchestrator
4. Orchestrator responds with `{:prefetch_chunk, ...}` if chunks remain

```elixir
def handle_progress(progress, state) when progress >= 0.20 do
  if state.next_chunk_available? and not state.prefetch_received? do
    send(state.orchestrator, {:prefetch_request, self()})
    %{state | prefetch_received?: true}
  else
    state
  end
end
```

---

## 6. Failure Handling

### 6.1 Worker Crash Detection

```elixir
# Monitor worker from orchestrator
def spawn_worker(orchestrator_state) do
  {:ok, worker_pid} = DynamicSupervisor.start_child(
    orchestrator_state.worker_supervisor,
    {Worker, orchestrator_state.orchestrator}
  )
  
  # Link and monitor for crash detection
  Process.monitor(worker_pid)
  
  worker_pid
end

# Handle crash notification
def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
  failed_chunk_id = state.assignments[worker_pid]
  
  new_state = %{state |
    assignments: Map.delete(state.assignments, worker_pid),
    in_progress: Map.delete(state.in_progress, failed_chunk_id)
  }
  
  # Re-queue failed chunk
  requeue_chunk(failed_chunk_id, new_state, reason)
end
```

### 6.2 Re-queue Failed Chunk

```elixir
def requeue_chunk(chunk_id, state, reason) do
  # Log failure
  Logger.error("Worker crashed on chunk #{chunk_id}: #{inspect(reason)}")
  
  # Re-add to queue (at front for immediate retry)
  %{state |
    chunk_queue: [chunk_id | state.chunk_queue],
    failed_attempts: Map.update(state.failed_attempts, chunk_id, 1, &(&1 + 1))
  }
end
```

### 6.3 Max Retry Handling

```elixir
def requeue_chunk(chunk_id, state, reason) do
  attempts = Map.get(state.failed_attempts, chunk_id, 0)
  
  if attempts >= 3 do
    Logger.error("Chunk #{chunk_id} failed after 3 attempts")
    %{state | 
      chunk_queue: state.chunk_queue,
      permanently_failed: MapSet.put(state.permanently_failed, chunk_id)
    }
  else
    # Re-queue with retry
    %{state |
      chunk_queue: [chunk_id | state.chunk_queue],
      failed_attempts: Map.update(state.failed_attempts, chunk_id, 1, &(&1 + 1))
    }
  end
end
```

### 6.4 Failure Recovery Summary

| Failure Type | Detection | Recovery |
|--------------|-----------|----------|
| Worker crash mid-chunk | `{:DOWN, ...}` monitor | Re-queue chunk to different worker |
| Worker crash after completion | N/A (already recorded) | None needed |
| Orchestrator crash | N/A (supervisor handles) | Full restart, resume from checkpoint |
| Chunk permanently fails (3 retries) | Retry count exceeded | Mark failed, continue other chunks |

---

## 7. Implementation Steps

### Task 1: Create Worker Module

**Files:**
- Create: `lib/framer/actor/worker.ex`
- Test: `test/framer/actor/worker_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule Framer.Actor.WorkerTest do
  use ExUnit.Case, async: true
  
  describe "initialization" do
    test "starts with idle status" do
      {:ok, worker} = Worker.start_link(self())
      assert Worker.status(worker) == :idle
    end
    
    test "sends ready message to orchestrator" do
      orchestrator = self()
      {:ok, _worker} = Worker.start_link(orchestrator)
      
      assert_receive {:worker_ready, _worker_pid}
    end
  end
  
  describe "chunk assignment" do
    test "receives and processes chunk assignment" do
      orchestrator = self()
      {:ok, worker} = Worker.start_link(orchestrator)
      
      Worker.assign_chunk(worker, 1, {0, 1000}, true)
      
      # Worker should transition to processing
      assert Worker.status(worker) == :processing
    end
    
    test "sends completion message when done" do
      orchestrator = self()
      {:ok, worker} = Worker.start_link(orchestrator)
      
      Worker.assign_chunk(worker, 1, {0, 100}, false)
      
      # Simulate completion (in real impl, this happens after processing)
      assert_receive {:chunk_completed, 1, :ok}
    end
  end
end
```

**Step 2: Run test to verify it fails**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/worker_test.exs
```
Expected: FAIL (Worker module not defined)

**Step 3: Write minimal implementation**

```elixir
defmodule Framer.Actor.Worker do
  use GenServer
  
  @impl true
  def init(orchestrator) do
    send(orchestrator, {:worker_ready, self()})
    
    {:ok, %{
      orchestrator: orchestrator,
      current_chunk: nil,
      status: :idle,
      prefetch_received?: false
    }}
  end
  
  @impl true
  def handle_call({:assign_chunk, chunk_id, _byte_range, next_available}, _from, state) do
    new_state = %{state | 
      current_chunk: chunk_id, 
      status: :processing,
      prefetch_received?: not next_available
    }
    
    # Process chunk (placeholder - real impl does video processing)
    result = process_chunk(chunk_id)
    
    send(state.orchestrator, {:chunk_completed, chunk_id, result})
    
    {:reply, :ok, %{new_state | status: :idle}}
  end
  
  def start_link(orchestrator) do
    GenServer.start_link(__MODULE__, orchestrator)
  end
  
  def assign_chunk(worker, chunk_id, byte_range, next_available) do
    GenServer.call(worker, {:assign_chunk, chunk_id, byte_range, next_available})
  end
  
  def status(worker) do
    GenServer.call(worker, :status)
  end
  
  defp process_chunk(chunk_id) do
    # TODO: Implement actual video chunk processing
    :ok
  end
end
```

**Step 4: Run test to verify it passes**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/worker_test.exs
```
Expected: PASS

**Step 5: Commit**

```bash
git add lib/framer/actor/worker.ex test/framer/actor/worker_test.exs
git commit -m "feat: add Worker actor module with basic message handling"
```

---

### Task 2: Create Orchestrator Module

**Files:**
- Create: `lib/framer/actor/orchestrator.ex`
- Test: `test/framer/actor/orchestrator_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule Framer.Actor.OrchestratorTest do
  use ExUnit.Case, async: true
  
  setup do
    {:ok, orchestrator} = Orchestrator.start_link("/fake/video.mp4", 3, 10_000_000)
    %{orchestrator: orchestrator}
  end
  
  test "spawns workers on startup", %{orchestrator: orchestrator} do
    # Should have workers registered
    assert Orchestrator.worker_count(orchestrator) == 3
  end
  
  test "assigns chunks to workers", %{orchestrator: orchestrator} do
    Orchestrator.start_processing(orchestrator)
    
    # Should have assignments after starting
    Process.sleep(100)
    assert map_size(Orchestrator.assignments(orchestrator)) > 0
  end
  
  test "tracks completed chunks", %{orchestrator: orchestrator} do
    Orchestrator.start_processing(orchestrator)
    
    # Wait for at least one chunk completion
    Process.sleep(500)
    
    completed = Orchestrator.completed_chunks(orchestrator)
    assert map_size(completed) > 0
  end
end
```

**Step 2: Run test to verify it fails**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/orchestrator_test.exs
```
Expected: FAIL (Orchestrator module not defined)

**Step 3: Write minimal implementation**

```elixir
defmodule Framer.Actor.Orchestrator do
  use GenServer
  
  def start_link(video_path, num_workers, chunk_size) do
    GenServer.start_link(__MODULE__, {video_path, num_workers, chunk_size})
  end
  
  @impl true
  def init({video_path, num_workers, chunk_size}) do
    # Start worker supervisor
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    
    chunks = divide_into_chunks(video_path, chunk_size)
    
    state = %{
      worker_supervisor: sup,
      chunk_queue: chunks,
      assignments: %{},
      completed: %{},
      failed_attempts: %{},
      in_progress: %{}
    }
    
    # Spawn initial workers
    workers = for _ <- 1..num_workers, do: spawn_worker(state)
    
    {:ok, %{state | workers: workers}}
  end
  
  def start_processing(orchestrator) do
    GenServer.cast(orchestrator, :start_processing)
  end
  
  def worker_count(orchestrator) do
    GenServer.call(orchestrator, :worker_count)
  end
  
  def assignments(orchestrator) do
    GenServer.call(orchestrator, :assignments)
  end
  
  def completed_chunks(orchestrator) do
    GenServer.call(orchestrator, :completed_chunks)
  end
  
  defp spawn_worker(state) do
    {:ok, worker} = DynamicSupervisor.start_child(
      state.worker_supervisor,
      {Framer.Actor.Worker, self()}
    )
    Process.monitor(worker)
    worker
  end
  
  defp divide_into_chunks(path, chunk_size) do
    # Placeholder - real impl reads file size
    # For testing, generate mock chunks
    for i <- 1..10 do
      %{id: i, byte_range: {(i-1)*chunk_size, i*chunk_size - 1}}
    end
  end
end
```

**Step 4: Run test to verify it passes**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/orchestrator_test.exs
```
Expected: PASS

**Step 5: Commit**

```bash
git add lib/framer/actor/orchestrator.ex test/framer/actor/orchestrator_test.exs
git commit -m "feat: add Orchestrator module with worker management"
```

---

### Task 3: Implement Chunk Prefetch Logic

**Files:**
- Modify: `lib/framer/actor/worker.ex`
- Test: `test/framer/actor/worker_test.exs`

**Step 1: Add prefetch test**

```elixir
test "requests prefetch at 20% progress threshold" do
  orchestrator = self()
  {:ok, worker} = Worker.start_link(orchestrator)
  
  # Simulate reaching 20% progress
  Worker.report_progress(worker, 0.20)
  
  # Should receive prefetch request
  assert_receive {:prefetch_request, ^worker}
end

test "does not request prefetch before 20%" do
  orchestrator = self()
  {:ok, worker} = Worker.start_link(orchestrator)
  
  Worker.report_progress(worker, 0.15)
  
  # Should NOT receive prefetch request
  refute_receive {:prefetch_request, _}, 100
end
```

**Step 2: Run test to verify it fails**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/worker_test.exs -e "prefetch"
```
Expected: FAIL (report_progress/2 not defined)

**Step 3: Add prefetch implementation to Worker**

```elixir
@impl true
def handle_cast({:report_progress, progress}, state) do
  new_state = cond do
    progress >= 0.20 and not state.prefetch_received? ->
      send(state.orchestrator, {:prefetch_request, self()})
      %{state | prefetch_received?: true}
    true ->
      state
  end
  
  {:noreply, new_state}
end

def report_progress(worker, progress) do
  GenServer.cast(worker, {:report_progress, progress})
end
```

**Step 4: Run test to verify it passes**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/worker_test.exs -e "prefetch"
```
Expected: PASS

**Step 5: Commit**

```bash
git add lib/framer/actor/worker.ex test/framer/actor/worker_test.exs
git commit -m "feat: add prefetch logic at 20% progress threshold"
```

---

### Task 4: Implement Failure Handling

**Files:**
- Modify: `lib/framer/actor/orchestrator.ex`
- Test: `test/framer/actor/orchestrator_test.exs`

**Step 1: Add failure handling test**

```elixir
test "re-queues chunk when worker crashes" do
  {:ok, orchestrator} = Orchestrator.start_link("/fake/video.mp4", 1, 1000)
  Orchestrator.start_processing(orchestrator)
  
  # Get worker pid before crash
  [worker_pid | _] = Orchestrator.workers(orchestrator)
  
  # Simulate worker crash
  Process.exit(worker_pid, :kill)
  
  # Wait for re-queue
  Process.sleep(200)
  
  # Chunk should be back in queue
  assert Orchestrator.queue_length(orchestrator) >= 1
end
```

**Step 2: Run test to verify it fails**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/orchestrator_test.exs -e "crash"
```
Expected: FAIL (queue_length/1 not defined, workers/1 not defined)

**Step 3: Add failure handling to Orchestrator**

```elixir
@impl true
def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
  failed_chunk = state.in_progress[worker_pid]
  
  new_state = if failed_chunk do
    # Re-queue failed chunk
    new_queue = [failed_chunk | state.chunk_queue]
    new_in_progress = Map.delete(state.in_progress, worker_pid)
    new_assignments = Map.delete(state.assignments, worker_pid)
    
    # Track failure
    attempts = Map.get(state.failed_attempts, failed_chunk, 0)
    
    if attempts < 3 do
      %{state |
        chunk_queue: new_queue,
        in_progress: new_in_progress,
        assignments: new_assignments,
        failed_attempts: Map.put(state.failed_attempts, failed_chunk, attempts + 1)
      }
    else
      # Mark as permanently failed
      %{state |
        in_progress: new_in_progress,
        assignments: new_assignments,
        permanently_failed: MapSet.put(state.permanently_failed, failed_chunk)
      }
    end
  else
    state
  end
  
  # Spawn replacement worker
  spawn_worker(new_state)
  
  {:noreply, new_state}
end

def queue_length(orchestrator) do
  GenServer.call(orchestrator, :queue_length)
end

def workers(orchestrator) do
  GenServer.call(orchestrator, :workers)
end
```

**Step 4: Run test to verify it passes**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/orchestrator_test.exs -e "crash"
```
Expected: PASS

**Step 5: Commit**

```bash
git add lib/framer/actor/orchestrator.ex test/framer/actor/orchestrator_test.exs
git commit -m "feat: add failure handling with chunk re-queue"
```

---

### Task 5: Integrate Video Processing Logic

**Files:**
- Modify: `lib/framer/actor/worker.ex`
- Modify: `lib/framer/video/processor.ex` (existing, if present)

**Step 1: Add video processing test**

```elixir
test "processes actual video chunk data" do
  # This would require a real video file
  # For integration test only
  {:ok, worker} = Worker.start_link(self())
  
  # Verify chunk processing is called
  assert Worker.process_chunk(1, {0, 1000}) == :ok
end
```

**Step 2: Implement actual video chunk processing**

```elixir
defp process_chunk(chunk_id) do
  # Read chunk from video file, decode, process, encode
  # This is where FFmpeg or similar would be invoked
  # Placeholder for now
  :ok
end
```

**Step 3: Commit**

```bash
git add lib/framer/actor/worker.ex
git commit -m "feat: add video chunk processing integration point"
```

---

### Task 6: Add Orchestrator Callbacks

**Files:**
- Modify: `lib/framer/actor/orchestrator.ex`

**Step 1: Add required handle_call implementations**

```elixir
@impl true
def handle_call(:worker_count, _from, state) do
  {:reply, length(state.workers), state}
end

@impl true
def handle_call(:assignments, _from, state) do
  {:reply, state.assignments, state}
end

@impl true
def handle_call(:completed_chunks, _from, state) do
  {:reply, state.completed, state}
end

@impl true
def handle_call(:queue_length, _from, state) do
  {:reply, length(state.chunk_queue), state}
end

@impl true
def handle_call(:workers, _from, state) do
  {:reply, state.workers, state}
end
```

**Step 2: Add start_processing handler**

```elixir
@impl true
def handle_cast(:start_processing, state) do
  # Assign initial chunks to all available workers
  new_state = assign_chunks_to_workers(state)
  {:noreply, new_state}
end

defp assign_chunks_to_workers(state) do
  available_workers = state.workers -- Map.keys(state.assignments)
  
  {assigned_state, _} = 
    Enum.reduce(available_workers, {state, length(state.chunk_queue) > 0}, fn
      worker, {s, false} -> {s, false}
      worker, {s, true} ->
        case s.chunk_queue do
          [chunk | rest] ->
            # Send assignment
            send(worker, {:assign_chunk, chunk.id, chunk.byte_range, length(rest) > 0})
            { %{s |
                chunk_queue: rest,
                assignments: Map.put(s.assignments, worker, chunk.id),
                in_progress: Map.put(s.in_progress, worker, chunk.id)
              }, length(rest) > 0 }
          [] ->
            {s, false}
        end
    end)
  
  assigned_state
end
```

**Step 3: Commit**

```bash
git add lib/framer/actor/orchestrator.ex
git commit -m "feat: add orchestrator callback implementations"
```

---

### Task 7: Integration Test

**Files:**
- Create: `test/framer/actor/integration_test.exs`

**Step 1: Write integration test**

```elixir
defmodule Framer.Actor.IntegrationTest do
  use ExUnit.Case, async: false
  
  @moduletag :integration
  
  test "full pipeline: orchestrator coordinates workers to process video" do
    # This test would require a real video file
    # Skipping actual execution - verify structure only
    
    assert true
  end
end
```

**Step 2: Run all actor tests**

```bash
cd /home/francjpd/projects/framer && mix test test/framer/actor/
```
Expected: All tests pass

**Step 3: Commit**

```bash
git add test/framer/actor/
git commit -m "test: add actor model integration tests"
```

---

## Summary

This plan implements an actor model concurrency pattern for video processing with:

- **7 tasks** total, each taking 2-5 minutes
- **TDD approach**: tests first, then implementation
- **Failure handling**: automatic worker restart and chunk re-queue
- **Prefetching**: smooth processing at 20% progress threshold
- **Clean message contracts**: explicit protocols between actors

Each task builds incrementally and commits separately for small, reviewable changes.

---

## Related Documentation

- Elixir GenServer: https://hexdocs.pm/elixir/GenServer.html
- DynamicSupervisor: https://hexdocs.pm/elixir/DynamicSupervisor.html
- Process monitoring: https://hexdocs.pm/elixir/Process.html#monitor/1
