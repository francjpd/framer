# Improved Video Looper - Implementation Plan

> **For Claude:** Use superpowers:subagent-driven-development to implement

**Goal:** Significantly improve video loop quality with better matching, crossfading, and interpolation

**Architecture:** Optical flow similarity + multi-point scanning + Gaussian crossfade + frame interpolation

---

## Task 1: Improve Optical Flow Similarity

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add optical flow similarity function**

```python
def compute_optical_flow_similarity(frame1, frame2):
    """Compare motion patterns between frames using optical flow."""
    gray1 = cv2.cvtColor(frame1, cv2.COLOR_BGR2GRAY)
    gray2 = cv2.cvtColor(frame2, cv2.COLOR_BGR2GRAY)
    
    # Compute optical flow
    flow = cv2.calcOpticalFlowFarneback(
        gray1, gray2, None,
        0.5, 3, 15, 3, 5, 1.2, 0
    )
    
    # Compute flow magnitude and angle
    magnitude = np.sqrt(flow[..., 0]**2 + flow[..., 1]**2)
    angle = np.arctan2(flow[..., 1], flow[..., 0])
    
    # Normalize
    mag_norm = magnitude / (magnitude.max() + 1e-6)
    angle_norm = (angle + np.pi) / (2 * np.pi)
    
    # Combine as feature vector
    features = np.stack([mag_norm, angle_norm], axis=-1)
    
    return features
```

**Step 2: Compare flow fields between frame pairs**

```python
def compute_flow_similarity_score(frame1, frame2, frame1_next, frame2_next):
    """
    Compare motion patterns between two frame pairs.
    Higher score = more similar motion patterns.
    """
    # Get flow from frame1->frame1_next and frame2->frame2_next
    flow1 = compute_optical_flow_similarity(frame1, frame1_next)
    flow2 = compute_optical_flow_similarity(frame2, frame2_next)
    
    # Compare flow fields (avoid exact position matching)
    # Use structural similarity on flow magnitude/angle
    mag_sim = 1 - np.abs(flow1[..., 0] - flow2[..., 0]).mean()
    angle_sim = 1 - np.abs(flow1[..., 1] - flow2[..., 1]).mean()
    
    score = (mag_sim * 0.7 + angle_sim * 0.3) * 100
    return max(0, min(100, score))
```

**Step 3: Update similarity function to support both methods**

```python
def compute_frame_similarity(frame1, frame2, method="optical_flow"):
    """Compute similarity between two frames."""
    if method == "optical_flow":
        gray1 = cv2.cvtColor(frame1, cv2.COLOR_BGR2GRAY)
        gray2 = cv2.cvtColor(frame2, cv2.COLOR_BGR2GRAY)
        
        flow = cv2.calcOpticalFlowFarneback(
            gray1, gray2, None,
            0.5, 3, 15, 3, 5, 1.2, 0
        )
        
        # Use inverse of average motion magnitude as similarity
        magnitude = np.sqrt(flow[..., 0]**2 + flow[..., 1]**2)
        avg_motion = np.mean(magnitude)
        
        # More motion = less similar (0-100 scale)
        # Scale: 0 motion = 100 similarity, 20+ motion = 0 similarity
        similarity = max(0, 100 - avg_motion * 5)
        return similarity
    
    elif method == "mse":
        mse = np.mean((frame1.astype(float) - frame2.astype(float)) ** 2)
        similarity = max(0, 100 - mse / 10)
        return similarity
    
    else:
        raise ValueError(f"Unknown method: {method}")
```

**Step 4: Commit**

```bash
git add ops/loop.py
git commit -m "feat(loop): add optical flow similarity matching"
```

---

## Task 2: Multi-point Scanning

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add scanning function**

```python
def find_best_loop_points(frames, scan_range=100, threshold=70):
    """
    Scan video for best loop points.
    
    Returns: (start_idx, end_idx, score)
    - start_idx: frame to start loop from
    - end_idx: frame to end loop at (before repeating)
    """
    if len(frames) < scan_range * 2:
        scan_range = len(frames) // 4
    
    best_score = 0
    best_start = 0
    best_end = len(frames) - 1
    
    # Scan first portion for potential start points
    for start_idx in range(min(scan_range, len(frames) - scan_range)):
        # Scan last portion for potential end points  
        for end_idx in range(max(scan_range, len(frames) - scan_range), len(frames)):
            # Compute similarity between start and end frames
            score = compute_frame_similarity(frames[start_idx], frames[end_idx])
            
            if score > best_score:
                best_score = score
                best_start = start_idx
                best_end = end_idx
    
    if best_score >= threshold:
        return (best_start, best_end, best_score)
    return (None, None, best_score)
```

**Step 2: Commit**

```bash
git add ops/loop.py  
git commit -m "feat(loop): add multi-point scanning for better loop points"
```

---

## Task 3: Gaussian Crossfade

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add Gaussian crossfade function**

```python
def create_gaussian_crossfade(frames, start_idx, end_idx, transition_frames=10):
    """
    Create smooth crossfade using Gaussian-weighted blending.
    """
    if transition_frames <= 0:
        return frames[start_idx:end_idx+1]
    
    # Get frames before and after transition point
    pre_frames = frames[start_idx:start_idx + transition_frames]
    post_frames = frames[end_idx - transition_frames + 1:end_idx + 1]
    
    if len(pre_frames) == 0 or len(post_frames) == 0:
        return frames[start_idx:end_idx+1]
    
    # Create Gaussian weights
    t = np.linspace(0, np.pi, max(len(pre_frames), len(post_frames)))
    weights = (np.sin(t) + 1) / 2  # 0 to 1 to 0 pattern
    
    blended = []
    min_len = min(len(pre_frames), len(post_frames))
    
    for i in range(min_len):
        w = weights[i] if i < len(weights) else weights[-1]
        
        # Blend: pre * (1-w) + post * w
        blended_frame = cv2.addWeighted(
            pre_frames[i], 1 - w,
            post_frames[i], w,
            0
        )
        blended.append(blended_frame)
    
    # Build result: frames before transition + blended + frames after
    result = frames[:start_idx] + blended + frames[end_idx + 1:]
    return result
```

**Step 2: Commit**

```bash
git add ops/loop.py
git commit -m "feat(loop): add Gaussian-weighted crossfade"
```

---

## Task 4: Frame Interpolation

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add interpolation function**

```python
def interpolate_frames(frame1, frame2, num_intermediate=5):
    """
    Generate intermediate frames between two frames using optical flow.
    """
    if num_intermediate <= 0:
        return []
    
    gray1 = cv2.cvtColor(frame1, cv2.COLOR_BGR2GRAY)
    gray2 = cv2.cvtColor(frame2, cv2.COLOR_BGR2GRAY)
    
    # Compute forward flow
    flow = cv2.calcOpticalFlowFarneback(
        gray1, gray2, None,
        0.5, 3, 15, 3, 5, 1.2, 0
    )
    
    interpolated = []
    
    for i in range(1, num_intermediate + 1):
        t = i / (num_intermediate + 1)  # 0 to 1
        
        # Warp frame1 toward frame2 based on flow
        h, w = gray1.shape
        flow_map = flow * t
        
        # Create meshgrid
        x, y = np.meshgrid(np.arange(w), np.arange(h))
        map_x = (x + flow_map[..., 0]).astype(np.float32)
        map_y = (y + flow_map[..., 1]).astype(np.float32)
        
        # Remap
        warped = cv2.remap(frame1, map_x, map_y, cv2.INTER_LINEAR)
        
        # Blend with frame2
        result = cv2.addWeighted(warped, 1 - t, frame2, t, 0)
        interpolated.append(result)
    
    return interpolated
```

**Step 2: Add interpolate loop method**

```python
def create_loop_interpolate(frames, start_idx, end_idx, num_interp=10):
    """
    Create loop with interpolated transition frames.
    """
    # Get frames to transition between
    last_frames = frames[end_idx:]
    first_frames = frames[:start_idx + 1]
    
    if not last_frames or not first_frames:
        return frames[start_idx:end_idx+1]
    
    # Generate interpolated frames
    interp_frames = interpolate_frames(
        last_frames[-1], first_frames[0], num_interp
    )
    
    # Build result
    result = frames[:end_idx] + interp_frames + first_frames
    return result
```

**Step 3: Commit**

```bash
git add ops/loop.py
git commit -m "feat(loop): add frame interpolation for smooth transitions"
```

---

## Task 5: Update CLI Arguments

**Files:**
- Modify: `ops/loop.py`

**Step 1: Update args schema**

```python
register_operation(
    "loop",
    create_loop,
    {
        "method": {
            "type": "string",
            "default": "auto",
            "description": "Loop method: cut, crossfade, interpolate, auto"
        },
        "scan_frames": {
            "type": "int",
            "default": 100,
            "description": "Frames to scan for matching"
        },
        "transition_frames": {
            "type": "int",
            "default": 10,
            "description": "Frames for crossfade transition"
        },
        "match_threshold": {
            "type": "int",
            "default": 70,
            "description": "Minimum similarity threshold"
        },
        "interpolate": {
            "type": "bool",
            "default": False,
            "description": "Add interpolated frames for smoother loop"
        },
        "similarity_method": {
            "type": "string",
            "default": "optical_flow",
            "description": "Similarity method: mse or optical_flow"
        },
    },
    description="Create seamless infinite video loops",
)
```

**Step 2: Update create_loop to use new parameters**

Add parameters:
- scan_frames
- transition_frames  
- interpolate
- similarity_method

**Step 3: Commit**

```bash
git add ops/loop.py
git commit -m "feat(loop): add improved CLI arguments"
```

---

## Task 6: Integration Testing

**Files:**
- Test with real video

**Step 1: Test with various settings**

```bash
# Test optical flow matching
python cli.py input.webm out1.webm loop --method auto --similarity_method optical_flow

# Test with interpolation  
python cli.py input.webm out2.webm loop --interpolate --transition-frames 15

# Test crossfade
python cli.py input.webm out3.webm loop --method crossfade --transition-frames 10
```

**Step 2: Compare results**

Check which produces the smoothest loop.

**Step 3: Commit**

```bash
git add -A
git commit -m "test(loop): verify improved loop quality"
```

---

## Summary

Tasks:
1. Optical flow similarity (4 steps)
2. Multi-point scanning (2 steps)
3. Gaussian crossfade (2 steps)
4. Frame interpolation (3 steps)
5. CLI updates (3 steps)
6. Integration test (3 steps)

Total: ~18 steps
