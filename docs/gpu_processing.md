# Framer GPU Processing Architecture

Welcome to the documentation for how `Framer` handles GPU processing! 

## The Challenge: GPU Bottlenecks
When processing video frames in parallel using multiple worker processes, a common temptation is to send *all* computations to the GPU. However, the GPU is a shared resource. When multiple CPU processes simultaneously attempt to transfer memory to the GPU, execute kernels, and retrieve the results, they encounter **resource contention**.

As workers queue up for GPU access, the GPU becomes a bottleneck, and overall performance can actually *degrade* compared to single-threaded GPU execution.

## The Dynamic Work-Stealing Pool Model (10% Chunks)

To fix this contention issue and maximize total system throughput, Framer implements a **Dynamic Work-Stealing Pool Model**. Work is distributed in **10% chunks** that players can grab when they're free.

### How It Works

1. **The Work Pool**: Total video frames = 100% pool
2. **10% Chunks**: Each player grabs up to 10% of the remaining pool
3. **Dynamic Stealing**: When a player finishes their chunk, they grab another 10%
4. **Players**:
   - **Each GPU**: A separate player that can take up to 10% per GPU
   - **CPU**: Acts as a single player (10% max), splits internally across cores

### Example Scenarios

**Single GPU + CPU:**
- GPU takes 10%
- CPU takes 10%
- Remaining 80% waits for someone to finish
- GPU finishes → grabs another 10%
- CPU finishes → grabs another 10%
- And so on...

**Dual GPUs + CPU:**
- GPU 1 takes 10%
- GPU 2 takes 10%
- CPU takes 10%
- Remaining 70% waits
- GPU 1 finishes → grabs another 10%
- And so on...

### Why This Works

- **No Contention**: Each GPU has its own dedicated worker, eliminating lock contention
- **Dynamic Load Balancing**: Faster players naturally grab more work
- **CPU Cap**: CPU is capped at 10% to prevent it from overwhelming the GPU-focused pipeline
- **Efficient Utilization**: All available compute resources are saturated without stepping on each other's toes

## Summary

By using a dynamic work-stealing pool with 10% chunks:
- GPUs get dedicated workers (10% each)
- CPU acts as one player capped at 10%
- Work is distributed dynamically as workers finish
- Maximum system throughput without resource contention
