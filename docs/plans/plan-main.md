# Framer Video Processing System - Implementation Plan

> **For Claude:** Use superpowers:executing-plans to implement this plan.

**Goal:** Build a scalable, fault-tolerant video processing system deployable as CLI or web backend, using Elixir orchestration, Rust performance modules, and Python/CUDA GPU acceleration.

**Architecture:** Three-tier system with Elixir as the orchestration layer (Actor model for concurrency), Rust for low-level video processing, and Python with CUDA for GPU-accelerated transformations.

**Tech Stack:** Elixir (Orchestration), Rust (Performance), Python/CUDA (GPU), Phoenix (Web), Distillery (Deployment)

---

## 1.1 Integration Layer (The Glue)

The integration layer connects Elixir orchestration to Rust/Python processing. This is critical for achieving the elegance we want.

### Elixir ↔ Rust Integration (NIFs/Ports)

```elixir
# Elixir calls Rust - example interface
Framer.Rust.FrameDecoder.decode_frame(video_path, frame_number)
Framer.Rust.FrameBuffer.allocate(width, height, format)
Framer.Rust.Pipeline.process(chunk)
```

**Glue Components:**
| Module | Responsibility | Communication |
|--------|---------------|---------------|
| `Framer.Rust.NIF` | Load and manage Rust NIFs | Direct function calls |
| `Framer.Rust.Frame` | Convert between Elixir/Rust types | `Rustler` automatically handles encoding |
| `Framer.Rust.Buffer` | Manage shared memory for frames | Zero-copy where possible |

### Elixir ↔ Python Integration (Ports)

```elixir
# Elixir spawns Python worker with dedicated stdin/stdout
{:ok, pid} = Framer.Python.Worker.start_link(script: "filters.py")

# Send frame data via port
Framer.Python.Worker.apply_filter(pid, frame_data, :color_grading)

# Receive processed result
receive do
  {:processed, result} -> result
end
```

**Glue Components:**
| Module | Responsibility | Communication |
|--------|---------------|---------------|
| `Framer.Python.Worker` | Spawn and manage Python subprocess | Port (stdin/stdout) |
| `Framer.Python.Protocol` | Encode/decode messages to Python | JSON or MessagePack |
| `Framer.Python.Pool` | Pool of Python workers for parallelism | GenServer managing multiple ports |

### Chunk Flow (End-to-End)

```
1. User submits video
   │
   ▼
2. Orchestrator (Elixir) splits video into chunks
   │
   ▼
3. For each chunk:
   a. Elixir spawns/assigns worker
   b. Rust NIF extracts frames from video file
   c. Frame data sent to Python worker via Port
   d. Python applies GPU filters
   e. Result returned to Elixir
   f. Rust NIF reassembles output
   │
   ▼
4. Orchestrator combines chunks → final video
```

### Worker Inbox Pattern (Actor Model Implementation)

Each worker process has its own inbox - this is the "glue" that makes the system elegant:

```elixir
defmodule Framer.Worker do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:id]))
  end
  
  def handle_call({:process, chunk}, from, state) do
    # Process chunk via Rust → Python → Rust chain
    result = process_through_pipeline(chunk)
    {:reply, result, state}
  end
  
  # Worker requests more work when 80% done (20% remaining)
  def handle_info(:check_prefetch, state) do
    if near_completion?(state) do
      send(self(), {:request_chunk, self()})
    end
    {:noreply, state}
  end
end

defmodule Framer.Orchestrator do
  # Single process managing all workers
  # - Tracks chunk queue
  # - Receives prefetch requests
  # - Assigns next chunk to requesting worker
  # - No race conditions because only orchestrator assigns
end
```

### Message Contracts

| Message | From → To | Payload |
|---------|-----------|---------|
| `{:start_job, video_path, options}` | CLI/API → Orchestrator | video path, output config |
| `{:assign_chunk, chunk_id, frame_range}` | Orchestrator → Worker | chunk ID, start/end frames |
| `{:prefetch_request, worker_id}` | Worker → Orchestrator | "I need more work" |
| `{:chunk_assigned, chunk_id}` | Orchestrator → Worker | here's your chunk |
| `{:chunk_complete, chunk_id, result}` | Worker → Orchestrator | finished processing |
| `{:job_complete, job_id, output_path}` | Orchestrator → CLI/API | done!

### What We're Building

A distributed video processing system capable of handling complex video transformations at scale. The system will support multiple deployment modes:
- **CLI Mode:** Direct command-line interface for single-machine processing
- **API Mode:** REST/gRPC backend for web applications
- **Cluster Mode:** Distributed processing across multiple nodes

### Why This Architecture

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Orchestration | Elixir/OTP | Actor model for concurrency, fault tolerance via supervisors, hot code reloading |
| Performance | Rust | Zero-cost abstractions, memory safety, C-compatible FFI |
| GPU Acceleration | Python/CUDA | Mature ML/video libraries (FFmpeg, TensorRT, PyTorch), CUDA ecosystem |

### Core Features

- Video transcoding (format conversion, resolution scaling)
- GPU-accelerated filters (color grading, effects, AI enhancement)
- Batch processing with job queuing
- Real-time progress tracking
- Distributed task scheduling

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Deployment Modes                             │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐               │
│  │    CLI      │   │    API      │   │  Cluster    │               │
│  │  (Standalone)│   │  (Phoenix) │   │  (Libcluster)│               │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘               │
└─────────┼─────────────────┼─────────────────┼───────────────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Elixir Orchestration Layer                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │ Job Supervisor│  │Task Scheduler│  │State Manager │             │
│  │  (Dynamic)   │  │  (Priority)  │  │  (Registry)  │             │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘             │
└─────────┼─────────────────┼─────────────────┼─────────────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Rust Processing Layer                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │Video Decoder │  │ Frame Buffer │  │  Pipeline    │             │
│  │   (NIF)      │  │  (Memory)    │  │  Coordinator │             │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘             │
└─────────┼─────────────────┼─────────────────┼─────────────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Python/CUDA GPU Layer                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │FFmpeg CUDA   │  │ PyTorch/GPU  │  │  Custom      │             │
│  │  Filters     │  │  Transforms  │  │  Kernels     │             │
│  └──────────────┘  └──────────────┘  └──────────────┘             │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Input:** Video file or stream enters via CLI/API
2. **Job Creation:** Elixir job supervisor creates processing job actor
3. **Task Distribution:** Scheduler distributes frames/tasks to worker pool
4. **Rust Processing:** NIFs handle frame extraction and buffering
5. **GPU Processing:** Python workers apply CUDA-accelerated transforms
6. **Output:** Reassembled video written to destination

---

## 3. Key Components

### Elixir Components

| Component | Responsibility | Location |
|-----------|---------------|----------|
| `Framer.JobSupervisor` | Dynamic supervision of job processes | `lib/framer/job_supervisor.ex` |
| `Framer.TaskScheduler` | Priority queue and task distribution | `lib/framer/scheduler.ex` |
| `Framer.VideoRegistry` | Track active jobs and state | `lib/framer/registry.ex` |
| `Framer.API.Router` | Phoenix HTTP endpoints | `lib/framer_web/router.ex` |
| `Framer.Cluster` | Libcluster node discovery | `lib/framer/cluster.ex` |

### Rust Components

| Component | Responsibility | Location |
|-----------|---------------|----------|
| `video_decoder` | Extract frames from video formats | `rust/framer/src/decoder.rs` |
| `frame_buffer` | Manage frame memory efficiently | `rust/framer/src/buffer.rs` |
| `pipeline` | Coordinate processing pipeline | `rust/framer/src/pipeline.rs` |

### Python Components

| Component | Responsibility | Location |
|-----------|---------------|----------|
| `cuda_filters` | GPU-accelerated video filters | `python/framer/filters.py` |
| `torch_transforms` | ML-based transformations | `python/framer/transforms.py` |
| `ffmpeg_wrapper` | FFmpeg CUDA integration | `python/framer/ffmpeg.py` |

---

## 4. Implementation Phases

### Phase 1: Foundation (Weeks 1-3)

**Goal:** Core infrastructure and local processing working

| Step | Task | Deliverable |
|------|------|-------------|
| 1.1 | Set up Elixir project with Phoenix | `mix new framer --umbrella` |
| 1.2 | Configure Rust NIFs integration | Rustler setup in `rust/framer` |
| 1.3 | Create basic job actor system | `JobSupervisor` and `Job` GenServer |
| 1.4 | Implement video frame extraction in Rust | NIF returning frame data |
| 1.5 | Set up Python virtual environment | `python/requirements.txt` |
| 1.6 | Create FFmpeg wrapper for basic transcoding | Working CLI transcode |
| 1.7 | Wire Elixir → Rust → Python pipeline | End-to-end frame processing |

### Phase 2: GPU Acceleration (Weeks 4-6)

**Goal:** CUDA processing integrated

| Step | Task | Deliverable |
|------|------|-------------|
| 2.1 | Implement Rust frame buffer with CUDA pointers | Zero-copy frame passing |
| 2.2 | Create Python CUDA filter library | `cuda_filters` module |
| 2.3 | Add GPU filter node to Elixir pipeline | Configurable filter chain |
| 2.4 | Implement batch frame processing | Parallel GPU processing |
| 2.5 | Add memory management for GPU | Handle OOM gracefully |

### Phase 3: Distribution & API (Weeks 7-9)

**Goal:** Scalable deployment options

| Step | Task | Deliverable |
|------|------|-------------|
| 3.1 | Build Phoenix REST API | Job CRUD endpoints |
| 3.2 | Implement WebSocket progress streaming | Real-time status updates |
| 3.3 | Add Libcluster for node discovery | Cluster mode support |
| 3.4 | Create job persistence (PostgreSQL) | Resume jobs after restart |
| 3.5 | Implement rate limiting and auth | API security |

### Phase 4: Polish & Scale (Weeks 10-12)

**Goal:** Production-ready system

| Step | Task | Deliverable |
|------|------|-------------|
| 4.1 | Add comprehensive logging (Telemetry) | Observability |
| 4.2 | Implement graceful shutdown | Zero-downtime deploys |
| 4.3 | Add metrics (Prometheus) | Performance monitoring |
| 4.4 | Create Docker/Distillery releases | Deployment artifacts |
| 4.5 | Write integration tests | 80% coverage |

---

## 5. Success Criteria

### Functional Criteria

| Criterion | Verification |
|-----------|--------------|
| CLI can transcode video between formats | Run `framer transcode input.mp4 output.webm` successfully |
| API accepts job and returns progress | POST /api/jobs returns job_id, WebSocket shows progress |
| GPU filters apply correctly | Output video shows applied color/grayscale/enhancement |
| Cluster mode distributes work | Two nodes process different frames of same video |

### Performance Criteria

| Metric | Target |
|--------|--------|
| Frame processing latency | < 50ms per frame (1080p) |
| GPU utilization | > 80% during processing |
| API response time | < 200ms for job creation |
| Horizontal scaling | Linear throughput increase with nodes |

### Reliability Criteria

| Criterion | Verification |
|-----------|--------------|
| Supervisor recovers from worker crash | Kill Python worker, job continues |
| Jobs persist across restart | Stop/start system, job resumes |
| Graceful degradation | GPU unavailable, fall back to CPU |

---

## 6. Timeline & Milestones

### Milestone 1: MVP (Week 3)
- Basic CLI transcode working
- Elixir job system functional
- First frame processed through pipeline

### Milestone 2: GPU Ready (Week 6)
- CUDA filters operational
- Performance targets met
- Batch processing enabled

### Milestone 3: API Complete (Week 9)
- Full REST API
- WebSocket progress
- Cluster capable

### Milestone 4: Production (Week 12)
- Monitoring & metrics
- Docker deployment
- Integration tests passing

### Rough Timeline

```
Week:  1   2   3   4   5   6   7   8   9  10  11  12
       │   │   │   │   │   │   │   │   │   │   │   │
Phase: ├───────────────┼───────────────┼───────────────┤
       │   Foundation  │ GPU Accel     │ Distribution  │ Polish
       │               │               │   & API       │
M1:    └───────┐
            MVP
M2:            └───────────┐
                          GPU Ready
M3:                          └───────────┐
                                      API
M4:                                      └─────┘
                                           Production
```

---

## Appendix: Technology Choices

### Why Elixir/OTP?
- **Supervisors:** Automatic failure recovery
- **Actors:** Clean concurrency model for job workers
- **Distribution:** Built-in for cluster mode
- **Hot Code Reload:** Update without downtime

### Why Rust NIFs?
- **Performance:** Near-native speed for frame manipulation
- **Safety:** Memory safety without garbage collection
- **FFI:** Seamless C integration for video codecs

### Why Python/CUDA?
- **CUDA Libraries:** FFmpeg, PyTorch, TensorRT ecosystem
- **Rapid Development:** Fast iteration on new filters
- **Maturity:** Battle-tested GPU code

---

*Document Version: 1.0*
*Last Updated: 2026-03-12*
