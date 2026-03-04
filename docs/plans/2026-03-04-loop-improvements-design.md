# Improved Video Looper - Design

## Overview
Significantly improve video loop quality with better matching, crossfading, and frame interpolation.

## Improvements

### 1. Better Similarity Matching
- **Optical flow matching**: Compare motion vectors between frames, not just pixel values
- **Multi-scale comparison**: Compare at original resolution and downsampled
- **Weighted scoring**: Give more weight to motion consistency

### 2. Multi-point Scanning
- Scan entire video for best loop points (configurable range)
- Find multiple candidate match points, pick best
- Support scanning from any frame position

### 3. Improved Crossfade
- Gaussian-weighted blending (smoother than linear alpha)
- Motion-compensated crossfade using optical flow
- Configurable transition zone length

### 4. Frame Interpolation
- Generate intermediate frames using optical flow
- Create N interpolated frames between end and start
- Makes seamless transition even when poses don't match exactly

## CLI Interface
```bash
python cli.py input.mp4 output.mp4 loop \
  --method auto              # cut, crossfade, interpolate, auto
  --scan-frames 100          # Frames to scan at start/end (default: 100)
  --transition-frames 10     # Frames for crossfade (default: 10)
  --match-threshold 70       # Similarity threshold (default: 70)
  --interpolate              # Add interpolated frames for smoother loop
  --similarity-method mse    # mse or optical_flow
```

## Technical Approach

### Optical Flow Similarity
1. Convert frames to grayscale
2. Compute dense optical flow using Farneback algorithm
3. Compare flow fields between frame pairs
4. Score based on motion vector similarity

### Motion-Compensated Crossfade
1. Compute flow from last N frames to first N frames
2. Warp frames based on flow
3. Blend warped frames for smooth transition

### Frame Interpolation
1. Compute bidirectional optical flow between end and start
2. Generate intermediate frames at fractional timestamps
3. Use flow to interpolate pixel positions

## Implementation Priority
1. Improve optical flow similarity (higher quality matches)
2. Add multi-point scanning (better match finding)  
3. Improve crossfade (Gaussian blending)
4. Add frame interpolation (smoothest loops)
