# Ports Communication Plan: Elixir-Rust IPC

## Overview

Elixir handles orchestration using the actor model, while Rust handles performance-critical video processing. This document outlines the communication strategy between them.

## 1. Communication Patterns

### When to Use Ports

- **Long-running processes**: Video encoding/decoding that takes seconds to minutes
- **Isolation required**: Crash in Rust shouldn't bring down the Elixir VM
- **Stateful operations**: Rust process maintains state across multiple requests
- **Binary data**: Large video frames that benefit from zero-copy where possible

### When to Use NIFs

- **Microsecond-level operations**: Simple computations that need minimal overhead
- **Stateless calls**: One-shot transformations without persistent state
- **Atomic operations**: Quick image filters, format conversions

### Recommendation

Use **Ports** as the primary mechanism. Reserve NIFs for specific hot-path optimizations after profiling.

## 2. Message Protocol

### Options Compared

| Protocol | Speed | Readability | Elixir Support | Size |
|----------|-------|-------------|----------------|------|
| JSON | Slow | Excellent | Built-in | Large |
| MessagePack | Fast | Poor | msgpax | Small |
| ETF (Erlang Term Encoding) | Fastest | N/A | Built-in | Small |

### Recommendation

**Primary: ETF** for internal communication (Elixir ↔ Rust via ports)
- Built-in Elixir support via `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1`
- Rust can use `erlang` or `serde` crates
- No serialization overhead for basic types

**Secondary: MessagePack** for external APIs or logging/debugging
- Human-readable with `msgpax` library
- Useful for debugging with `msgpax.unpack!`

## 3. Chunk Transfer

### Video Frame Flow

```
Elixir (Orchestrator)
    │
    ├─ Command: {cmd: :process_frame, frame_id: 1, data: binary}
    │
Rust (Port Process)
    │
    ├─ Receives frame binary
    ├─ Processes frame (decode → transform → encode)
    │
    ├─ Response: {ok: frame_id, data: binary, metadata: map}
    │
Elixir ( receives result )
```

### Binary Transfer Strategy

1. **Small frames (< 1MB)**: Send via stdin/stdout as binary payload
2. **Large frames (> 1MB)**: Use file-based transfer with path in message
3. **Zero-copy**: For very large videos, use shared memory segments (advanced)

### Message Format (ETF)

```elixir
# Elixir → Rust
{:frame, frame_id, %{width: 1920, height: 1080, format: :rgb24}, frame_data}

# Rust → Elixir  
{:result, frame_id, :ok, processed_data, %{duration_ms: 16}}
{:result, frame_id, :error, reason}
```

## 4. Result Streaming

### Approach: Continuous Port Messaging

The Rust process runs as a long-lived subprocess. Results stream back via stdout.

```elixir
defmodule VideoProcessor do
  use GenServer
  
  def start_link(opts) do
    Port.open({:spawn, "rust_video_processor"}, [
      :binary,
      packet: 4,
      use_stdio: true
    ])
  end
  
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case :erlang.binary_to_term(data) do
      {:result, frame_id, status, payload, metadata} ->
        # Stream result to subscribers
        broadcast_result(frame_id, status, payload, metadata)
        {:noreply, state}
      
      {:progress, frame_id, percent} ->
        broadcast_progress(frame_id, percent)
        {:noreply, state}
    end
  end
end
```

### Backpressure Handling

- Rust should buffer results and send when Elixir acknowledges
- Elixir uses GenServer's message queue as natural backpressure
- Monitor process memory: pause if > 100MB queued

## 5. Error Handling

### Failure Categories

| Type | Detection | Recovery |
|------|-----------|----------|
| Rust crash | Port closes | Restart Rust process, resend last N frames |
| Timeout | No response in X ms | Retry with exponential backoff |
| Invalid data | Parse error | Log, skip frame, continue |
| Memory exhaustion | :enomem | Reduce batch size, GC |

### Error Protocol

```elixir
# Rust → Elixir error format
{:error, :timeout, "Frame 5 took > 30s"}
{:error, :crash, "Segmentation fault in ffmpeg"}
{:error, :invalid_input, "Frame 45: invalid H.264 stream"}
```

### Supervision Tree

```
Elixir.Application
  └─ Video.Supervisor
      ├─ FrameProcessor.Port (one_for_one)
      │   └─ RustProcess
      └─ FrameProcessor.Registry
```

## 6. Performance Considerations

### Latency Targets

| Operation | Target | Maximum |
|-----------|--------|---------|
| Frame round-trip | 10ms | 50ms |
| Process startup | 100ms | 500ms |
| Message parse | 0.1ms | 1ms |

### Memory Optimization

- **Minimize copies**: Use `:binary.copy` only when necessary
- **Binary stacking**: Pre-allocate buffers in Rust for frame data
- **Batching**: Send 4-8 frames together for throughput, not latency
- **pids vs ports**: For > 1000 msg/sec, consider Erlang distribution

### Batching Strategy

```elixir
# Batch frames for throughput
def process_batch(frames, opts \\ []) do
  batch_size = Keyword.get(opts, :batch_size, 4)
  
  frames
  |> Enum.chunk_every(batch_size)
  |> Enum.map(&send_batch/1)
  |> Enum.flat_map(& &1)
end
```

## 7. Implementation Steps

### Phase 1: Foundation
1. [ ] Create Rust CLI that reads frames from stdin, writes to stdout
2. [ ] Define message format (ETF)
3. [ ] Implement basic Port.open/1 in Elixir
4. [ ] Add GenServer wrapper for port management

### Phase 2: Communication
5. [ ] Implement request/response loop
6. [ ] Add frame serialization (Elixir binary → Rust)
7. [ ] Add result deserialization (Rust → Elixir)
8. [ ] Handle port close/reset

### Phase 3: Streaming
9. [ ] Implement result streaming (async responses)
10. [ ] Add progress reporting from Rust
11. [ ] Implement backpressure (flow control)

### Phase 4: Resilience
12. [ ] Add supervision with automatic restart
13. [ ] Implement timeout handling
14. [ ] Add retry logic with exponential backoff
15. [ ] Implement graceful shutdown

### Phase 5: Optimization
16. [ ] Profile latency with telemetry
17. [ ] Add batching for throughput
18. [ ] Consider shared memory for large frames (if needed)
19. [ ] Add connection pooling (multiple Rust processes)

## Quick Start

```bash
# Run Rust processor
cd rust_processor && cargo run

# In Elixir IEx
iex> {:ok, pid} = VideoProcessor.start_link()
iex> VideoProcessor.process_frame(pid, frame_data)
```

## File Structure

```
framer/
├── lib/
│   └── video/
│       ├── processor.ex        # GenServer port wrapper
│       ├── frame.ex            # Frame struct and serialization
│       └── codec.ex            # ETF encoding/decoding
├── rust/
│   ├── src/
│   │   ├── main.rs            # CLI entry point
│   │   ├── processor.rs       # Video processing logic
│   │   └── protocol.rs        # Message parsing
│   └── Cargo.toml
└── docs/
    └── plans/
        └── plan-ports.md
```

## References

- [Elixir Ports Documentation](https://hexdocs.pm/elixir/Port.html)
- [Rust erlang_term crate](https://crates.io/crates/erlang)
- [msgpax for MessagePack](https://hex.pm/packages/msgpax)
