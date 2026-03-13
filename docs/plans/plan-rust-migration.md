# Rust Migration Plan: Video Processing

## Overview

Migrate performance-critical video processing code from Python to Rust while maintaining GPU acceleration via CUDA/ROCm. Rust library will be callable from Elixir via NIFs or Ports.

---

## 1. Migration Strategy

**Recommended: Incremental Migration (Phased Approach)**

| Phase | Approach | Risk |
|-------|----------|------|
| Phase 1 | New Rust components only | Low |
| Phase 2 | Wrap existing Python, call from Rust | Medium |
| Phase 3 | Replace Python internals piece by piece | Medium |
| Phase 4 | Full Rust implementation | Low |

**Rationale:**
- Keep production running throughout migration
- Validate GPU access before rewriting
- Easier to isolate issues
- Can benchmark incrementally

**Alternative: Big-Bang** - Only if timeline is critical and team has Rust expertise.

---

## 2. Components to Migrate

### Priority 1: GPU-Intensive Core (Migrate First)
- Video frame decoding/encoding
- Tensor operations on GPU
- Neural network inference (if using PyTorch models)
- Color space conversions on GPU

### Priority 2: I/O Intensive (Migrate Second)
- File reading/writing
- Stream buffering
- Frame queue management

### Priority 3: Glue Logic (Migrate Last)
- Configuration parsing
- Error handling
- Logging/metrics

### Components to Keep in Python/Elixir
- Web server/API layer
- Task orchestration
- Database operations
- User-facing CLI

### Components to Keep in Python (Temporary)
- PyTorch model loading (until Rust alternatives mature)
- Complex preprocessing that changes frequently

---

## 3. GPU Integration

### Option A: CUDA Bindings (NVIDIA)
**Recommended for NVIDIA GPUs**

| Crate | Purpose |
|-------|---------|
| `cuda.rs` | Low-level CUDA driver bindings |
| `cudart` | CUDA runtime bindings |
| `cublas` | BLAS operations |
| `cudnn` | Deep learning primitives |
| `rust-gpu` | SPIR-V compilation (future) |

**Pros:** Full CUDA feature parity, mature ecosystem
**Cons:** NVIDIA only

### Option B: ROCm/AMD GPUs
| Crate | Purpose |
|-------|---------|
| `hip` | HIP runtime bindings |
| `amd-rocm` | ROCm ecosystem access |

**Pros:** AMD hardware support
**Cons:** Smaller ecosystem, less documentation

### Option C: Cross-Platform (OpenCL)
| Crate | Purpose |
|-------|---------|
| `ocl` | OpenCL bindings |
| `rusticl` | Alternative OpenCL |

**Pros:** Works on NVIDIA, AMD, Intel
**Cons:** Performance typically 10-20% below native CUDA

### Recommendation

```
if hardware == NVIDIA:
    use CUDA bindings (cudart, cublas)
else if hardware == AMD:
    use ROCm (hip crate)
else:
    use OpenCL as fallback
```

**Key insight:** Don't sacrifice GPU performance for portability. Use platform-specific backends with shared abstraction layer.

### GPU Memory Management
- Use `rustix` or `libc` for manual CUDA memory allocation if needed
- Implement memory pooling to reduce allocation overhead
- Track GPU memory usage explicitly (no automatic GC)

---

## 4. FFI/Elixir Integration

### Option A: NIFs (Native Implemented Functions)

**Pros:**
- Zero-copy possible (use `Binary` directly)
- Lowest latency
- Direct Erlang process integration

**Cons:**
- Unsafe code - bugs can crash BEAM
- Must handle resource cleanup manually
- Debugging native crashes is difficult
- Each NIF call blocks the scheduler

**When to use:**
- Latency-critical paths
- Small, focused functions
- When you need tight BEAM integration

### Option B: Ports (Elixir Ports)

**Pros:**
- Safe - crashes stay in port
- Simple to debug
- Language-agnostic
- Handles restarts gracefully

**Cons:**
- Serialization overhead (JSON/binary)
- Higher latency
- More complex state management

**When to use:**
- Complex stateful components
- When safety > performance
- When multiple Rust binaries needed

### Option C: CNode (Erlang Distribution)

**Pros:**
- Full OTP compatibility
- Location transparency
- Built-in error handling

**Cons:**
- Complex setup
- Overhead from serialization

**When to use:**
- Distributed systems
- When Rust service needs to scale independently

### Recommendation

```
Primary: NIFs for hot paths (frame processing)
Secondary: Ports for orchestration/management
```

**Implementation Pattern:**

```rust
// Rust NIF entry point
#[rustler::nif]
pub fn process_frame(frame: Binary, opts: Map) -> Result<Binary, String> {
    // GPU-accelerated processing here
}

// Port for batch operations
#[rustler::nif]
pub fn init_processor(gpu_device: i32) -> Result<Resource, String> {
    // Initialize GPU context, return handle
}
```

**Key libraries:**
- `rustler` - Elixir NIF framework
- `portable_tx` - Efficient binary serialization
- `erl_dist` - If using CNode

---

## 5. Testing Strategy

### Unit Tests (Rust)
```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_frame_resize() {
        // Compare output with reference implementation
    }
    
    #[test]
    fn test_gpu_cpu_parity() {
        // Run same operation on CPU and GPU, compare results
    }
}
```

### Integration Tests (Rust + Python)
- Run Python test suite against Rust implementation
- Golden output comparison
- Boundary condition tests

### Property-Based Testing
- Use `proptest` for fuzzing
- Generate random frames, verify invariants

### Testing Matrix

| Test Type | What | Tool |
|-----------|------|------|
| Unit | Individual functions | `cargo test` |
| GPU | GPU vs CPU parity | Custom harness |
| Integration | Python call wrapper | pytest |
| Property | Fuzzing | proptest |
| Benchmark | Performance | criterion |
| Regression | Full pipeline | CI pipeline |

### Validation Approach
1. **Golden files:** Compare output frames against known-good Python outputs
2. **Statistical tests:** For lossy operations (compression), verify metrics (PSNR, SSIM)
3. **Round-trip:** Encode → decode → verify identical
4. **Crash detection:** Sanitizers (ASan, MSan) in CI

---

## 6. Performance Benchmarks

### Benchmark Tools
- `criterion` - Rust benchmarking
- `pytest-benchmark` - Python comparison
- Custom GPU timing with CUDA events

### Key Metrics to Measure

| Metric | Target | Measurement |
|--------|--------|-------------|
| Frame throughput | >30% improvement | frames/sec |
| Latency P99 | <50% of Python | ms/frame |
| GPU utilization | >80% | nvidia-smi |
| Memory allocation | <Python | MB/frame |
| Cold start | <2s | time to first frame |

### Benchmark Suite

```rust
fn criterion_benchmark(c: &mut Criterion) {
    c.bench_function("resize_1080p", |b| {
        b.iter(|| process_frame(&input))
    });
}
```

### Comparison Points
1. **Python baseline:** Current OpenCV/PyTorch implementation
2. **Rust CPU:** Same algorithm, no GPU
3. **Rust GPU:** Full implementation

### GPU-Specific Benchmarks
- Memory transfer overhead (CPU ↔ GPU)
- Kernel launch latency
- Batch vs streaming performance
- Multi-GPU scaling

### Reporting
- Automated charts in CI
- Trend analysis over time
- Alert on >10% regression

---

## 7. Implementation Steps

### Phase 1: Foundation (Weeks 1-2)
- [ ] Set up Rust project structure with workspace
- [ ] Configure CUDA/ROCm toolchain
- [ ] Add GPU detection (auto-select backend)
- [ ] Create basic NIF/Port skeleton
- [ ] Set up CI with GPU runners

### Phase 2: Core GPU Operations (Weeks 3-4)
- [ ] Implement frame buffer management
- [ ] Add CUDA memory allocator
- [ ] Create GPU kernels for color conversion
- [ ] Implement resize/crop operations
- [ ] Verify GPU output matches CPU baseline

### Phase 3: Video Codecs (Weeks 5-6)
- [ ] Integrate video decoder (ffmpeg-sys or custom)
- [ ] Add encoder support
- [ ] Implement frame extraction/insertion
- [ ] Test with real video files

### Phase 4: ML Integration (Weeks 7-8)
- [ ] Load PyTorch models via `torch-sys` or ONNX Runtime
- [ ] Implement inference pipeline
- [ ] Add batch processing support
- [ ] Benchmark vs Python

### Phase 5: Elixir Integration (Weeks 9-10)
- [ ] Build NIF wrappers for hot paths
- [ ] Create Port-based batch processor
- [ ] Add error handling and recovery
- [ ] Implement resource management (drop, cleanup)

### Phase 6: Optimization (Weeks 11-12)
- [ ] Profile and optimize bottlenecks
- [ ] Add memory pooling
- [ ] Implement pipeline parallelism
- [ ] Multi-GPU support

### Phase 7: Production Readiness (Weeks 13-14)
- [ ] Comprehensive test suite
- [ ] Performance benchmarks in CI
- [ ] Documentation
- [ ] Release process

---

## 8. Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| GPU driver incompatibility | High | Version detection, fallback to CPU |
| NIF crashes BEAM | High | Use Ports for risky operations |
| Memory leaks | Medium | Resource management with Drop |
| Performance regression | Medium | CI benchmarks with alerts |
| CUDA/ROCm API changes | Low | Version-locked dependencies |
| Team Rust expertise | Medium | Pair programming, code review |

---

## 9. Dependencies

### Rust Crates (Core)
```toml
[dependencies]
cuda = "0.2"           # or hip for AMD
cublas = "0.2"         # BLAS operations
rustler = "0.32"       # NIF framework
serde = "1.0"          # Serialization
image = "0.25"         # Image processing
ffmpeg-next = "7"      # Video encoding/decoding

[dev-dependencies]
criterion = "0.5"      # Benchmarks
proptest = "1.4"       # Property testing
```

### External Requirements
- CUDA Toolkit 12.x (or ROCm 6.x for AMD)
- Clang/LLVM for CUDA compilation
- ffmpeg development libraries

---

## 10. Success Criteria

- [ ] Rust implementation passes all existing Python tests
- [ ] GPU throughput >30% improvement over Python
- [ ] Latency P99 <50% of Python baseline
- [ ] NIFs stable under load (no BEAM crashes)
- [ ] Multi-hour stress test passes
- [ ] Documentation complete

---

## Appendix: Quick Reference

### CUDA Memory Layout
```
Host (CPU)          Device (GPU)
    |                    |
    | cudaMalloc         |
    |------------------->|
    |                    |
    | cudaMemcpy         |
    |------------------->|
    |  Kernel Launch     |
    |------------------->|
    |                    | (compute)
    | cudaMemcpy (async) |
    |<-------------------|
```

### NIF Error Handling
```rust
#[rustler::nif]
pub fn process(frame: Binary) -> Result<Binary, String> {
    match do_process(&frame) {
        Ok(result) => Ok(result),
        Err(e) => Err(format!("GPU error: {}", e)),
    }
}
```

### GPU Detection
```rust
fn detect_gpu() -> GpuBackend {
    if std::path::Path::new("/usr/local/cuda").exists() {
        GpuBackend::CUDA
    } else if std::path::Path::new("/opt/rocm").exists() {
        GpuBackend::ROCm
    } else {
        GpuBackend::CPU
    }
}
```
