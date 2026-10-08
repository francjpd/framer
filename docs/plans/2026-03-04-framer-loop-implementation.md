# Video Looper Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add video looper feature to create seamless infinite loops and rename project to "framer"

**Architecture:** Extract first/last frames, compute pose/motion similarity, apply loop method (cut/crossfade/stretch)

**Tech Stack:** Python, OpenCV, NumPy, FFmpeg

---

## Task 1: Rename Project to Framer

**Files:**
- Modify: `bgremover.py` → rename to `framer.py`
- Modify: `README.md` - update title and references
- Modify: `pyproject.toml` - update project name (optional)
- Modify: `tests/test_bgremover.py` - update import

**Step 1: Rename bgremover.py to framer.py**

```bash
mv bgremover.py framer.py
```

**Step 2: Update imports in tests**

```python
# tests/test_bgremover.py - change:
from bgremover import ...
# to:
from framer import ...
```

**Step 3: Update README.md**

Update title and any references from "bg-remover" to "framer"

**Step 4: Commit**

```bash
git add -A && git mv bgremover.py framer.py
git commit -m "refactor: rename project to framer"
```

---

## Task 2: Add Loop Operation to Ops Registry

**Files:**
- Modify: `ops/__init__.py`

**Step 1: Check existing ops structure**

```python
# ops/__init__.py should have get_registry() function
# that returns operations registry
```

**Step 2: Add loop operation to registry**

```python
# Add to ops/__init__.py
def get_registry():
    return {
        "loop": {
            "func": create_loop,
            "description": "Create seamless infinite video loops",
            "args_schema": {
                "method": {"type": "string", "default": "auto"},
                "first_frames": {"type": "int", "default": 20},
                "last_frames": {"type": "int", "default": 20},
                "match_threshold": {"type": "int", "default": 85},
            }
        },
        # ... existing ops
    }
```

**Step 3: Run test to verify registry loads**

```bash
python -c "from ops import get_registry; print(get_registry().keys())"
```

Expected: includes "loop"

**Step 4: Commit**

```bash
git add ops/__init__.py
git commit -m "feat: add loop operation to registry"
```

---

## Task 3: Implement Frame Extraction

**Files:**
- Create: `ops/loop.py`

**Step 1: Write the test**

```python
# tests/test_loop.py
import pytest
from ops.loop import extract_frames

def test_extract_first_and_last_frames():
    # Use test-fps.webm or create small test video
    frames = extract_frames("test-fps.webm", first_n=5, last_n=5)
    assert "first" in frames
    assert "last" in frames
    assert len(frames["first"]) == 5
    assert len(frames["last"]) == 5
```

**Step 2: Run test to verify it fails**

```bash
pytest tests/test_loop.py -v
Expected: FAIL (module not found)

**Step 3: Write minimal implementation**

```python
# ops/loop.py
import cv2
import numpy as np
from pathlib import Path

def extract_frames(video_path, first_n=20, last_n=20):
    """Extract first N and last N frames from video."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")
    
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    
    # Extract first N frames
    first_frames = []
    for i in range(min(first_n, total_frames)):
        ret, frame = cap.read()
        if ret:
            first_frames.append(frame)
    
    # Extract last N frames
    cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, total_frames - last_n))
    last_frames = []
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        last_frames.append(frame)
    
    cap.release()
    return {"first": first_frames, "last": last_frames}
```

**Step 4: Run test to verify it passes**

```bash
pytest tests/test_loop.py -v
Expected: PASS

**Step 5: Commit**

```bash
git add ops/loop.py tests/test_loop.py
git commit -m "feat: add frame extraction for loop detection"
```

---

## Task 4: Implement Pose/Motion Similarity Detection

**Files:**
- Modify: `ops/loop.py`

**Step 1: Write the test**

```python
# Add to tests/test_loop.py
def test_compute_similarity():
    from ops.loop import compute_frame_similarity
    
    # Load same frame twice - should be 100% similar
    frame = np.zeros((100, 100, 3), dtype=np.uint8)
    score = compute_frame_similarity(frame, frame)
    assert score >= 95  # Same frame should be very similar
    
    # Different frames - lower score
    frame2 = np.ones((100, 100, 3), dtype=np.uint8) * 255
    score2 = compute_frame_similarity(frame, frame2)
    assert score2 < score
```

**Step 2: Run test to verify it fails**

```bash
pytest tests/test_loop.py::test_compute_similarity -v
Expected: FAIL

**Step 3: Write implementation - Optical Flow method**

```python
# Add to ops/loop.py
def compute_frame_similarity(frame1, frame2, method="optical_flow"):
    """
    Compute similarity between two frames.
    
    Returns: similarity score 0-100
    """
    if method == "optical_flow":
        gray1 = cv2.cvtColor(frame1, cv2.COLOR_BGR2GRAY)
        gray2 = cv2.cvtColor(frame2, cv2.COLOR_BGR2GRAY)
        
        # Compute optical flow
        flow = cv2.calcOpticalFlowFarneback(
            gray1, gray2, None,
            0.5, 3, 15, 3, 5, 1.2, 0
        )
        
        # Compute magnitude
        magnitude = np.sqrt(flow[..., 0]**2 + flow[..., 1]**2)
        
        # Similarity = inverse of average motion
        avg_motion = np.mean(magnitude)
        
        # Convert to 0-100 score (less motion = higher similarity)
        similarity = max(0, 100 - avg_motion)
        
        return similarity
    
    elif method == "mse":
        # Mean squared error
        mse = np.mean((frame1.astype(float) - frame2.astype(float)) ** 2)
        similarity = max(0, 100 - mse / 10)  # Scale factor
        return similarity
    
    else:
        raise ValueError(f"Unknown method: {method}")
```

**Step 4: Run test to verify it passes**

```bash
pytest tests/test_loop.py::test_compute_similarity -v
Expected: PASS

**Step 5: Commit**

```bash
git add ops/loop.py tests/test_loop.py
git commit -m "feat: add frame similarity computation"
```

---

## Task 5: Find Best Match Point

**Files:**
- Modify: `ops/loop.py`

**Step 1: Write the test**

```python
# Add to tests/test_loop.py
def test_find_best_match():
    from ops.loop import find_best_match_point
    
    # Create mock frames: first 3 frames, last 3 frames
    first_frames = [np.zeros((100, 100, 3), dtype=np.uint8) for _ in range(3)]
    last_frames = [np.zeros((100, 100, 3), dtype=np.uint8) for _ in range(3)]
    
    # Same frames should match well
    best_idx, score = find_best_match_point(first_frames, last_frames)
    assert best_idx is not None
    assert score > 80
```

**Step 2: Run test to verify it fails**

```bash
pytest tests/test_loop.py::test_find_best_match -v
Expected: FAIL

**Step 3: Write implementation**

```python
# Add to ops/loop.py
def find_best_match_point(first_frames, last_frames, threshold=85):
    """
    Find best matching frame pair between first and last frames.
    
    Returns: (best_first_idx, best_last_idx, similarity_score)
    """
    best_score = 0
    best_first_idx = 0
    best_last_idx = 0
    
    for i, first_frame in enumerate(first_frames):
        for j, last_frame in enumerate(last_frames):
            score = compute_frame_similarity(first_frame, last_frame)
            if score > best_score:
                best_score = score
                best_first_idx = i
                best_last_idx = j
    
    return (best_first_idx, best_last_idx, best_score) if best_score >= threshold else (None, None, best_score)
```

**Step 4: Run test to verify it passes**

```bash
pytest tests/test_loop.py::test_find_best_match -v
Expected: PASS

**Step 5: Commit**

```bash
git add ops/loop.py tests/test_loop.py
git commit -m "feat: add best match point detection"
```

---

## Task 6: Implement Loop Methods (Cut, Crossfade, Stretch)

**Files:**
- Modify: `ops/loop.py`

**Step 1: Write tests for each method**

```python
# Add to tests/test_loop.py
def test_loop_cut():
    # Test cut method creates valid output
    pass

def test_loop_crossfade():
    # Test crossfade creates blended frames
    pass
```

**Step 2: Implement cut method**

```python
# ops/loop.py
def create_loop_cut(frames, cut_first_idx, cut_last_idx):
    """
    Create loop by cutting from first frame to last frame at match point.
    
    frames: list of all frames
    cut_first_idx: index in first section to start loop
    cut_last_idx: index in last section to end loop
    """
    # Video structure: [first_frames...][middle_frames...][last_frames...]
    # Loop: start at cut_first_idx, end at cut_last_idx, then jump to start
    
    first_part = frames[:cut_first_idx + 1]
    loop_part = frames[cut_first_idx:]
    
    return first_part + loop_part
```

**Step 3: Implement crossfade method**

```python
def create_loop_crossfade(frames, first_n=5, last_n=5):
    """
    Create smooth loop by crossfading between end and start.
    """
    # Blend last N frames with first N frames
    blended = []
    
    for i in range(first_n):
        if i < len(frames[-last_n:]) and i < len(frames[:first_n]):
            last_frame = frames[-(last_n - i)]
            first_frame = frames[i]
            
            # Alpha blend: last_frame * alpha + first_frame * (1 - alpha)
            alpha = i / first_n
            blended_frame = cv2.addWeighted(
                last_frame, alpha,
                first_frame, 1 - alpha,
                0
            )
            blended.append(blended_frame)
    
    # Remove original overlapping frames
    result = frames[:-last_n] + blended + frames[first_n:]
    return result
```

**Step 4: Implement stretch method**

```python
def create_loop_stretch(frames, target_fps_factor=1.0):
    """
    Time-stretch frames to make loop seamless.
    """
    # Simple implementation: repeat frames to smooth transition
    # More advanced: use optical flow interpolation
    return frames  # Placeholder
```

**Step 5: Commit**

```bash
git add ops/loop.py
git commit -m "feat: implement loop creation methods"
```

---

## Task 7: Main Loop Function + CLI Integration

**Files:**
- Modify: `ops/loop.py`
- Modify: `ops/__init__.py`

**Step 1: Write main create_loop function**

```python
# ops/loop.py
def create_loop(input_path, output_path, method="auto", first_frames=20, 
                 last_frames=20, match_threshold=85, show_matches=False):
    """
    Main entry point for loop operation.
    """
    # 1. Extract frames
    frames_data = extract_frames(input_path, first_frames, last_frames)
    all_frames = frames_data["first"] + frames_data["middle"] + frames_data["last"]
    
    # 2. Find best match point
    first_idx, last_idx, score = find_best_match_point(
        frames_data["first"], frames_data["last"], match_threshold
    )
    
    if first_idx is None:
        return {"success": False, "error": f"No match found (best: {score}%)"}
    
    # 3. Apply loop method
    if method == "cut":
        looped_frames = create_loop_cut(all_frames, first_idx, last_idx)
    elif method == "crossfade":
        looped_frames = create_loop_crossfade(all_frames, first_idx, last_idx)
    elif method == "stretch":
        looped_frames = create_loop_stretch(all_frames)
    else:  # auto
        # Pick best method based on score
        if score >= 90:
            looped_frames = create_loop_cut(all_frames, first_idx, last_idx)
        else:
            looped_frames = create_loop_crossfade(all_frames, first_idx, last_idx)
    
    # 4. Encode output
    # Use FFmpeg to encode (similar to bgremover.py)
    encode_video(looped_frames, output_path, fps)
    
    return {"success": True, "output_path": output_path}
```

**Step 2: Update ops/__init__.py to import create_loop**

```python
from ops.loop import create_loop
```

**Step 3: Test CLI**

```bash
python cli.py test-fps.webm output-loop.webm loop --first-frames 10 --last-frames 10
```

**Step 4: Commit**

```bash
git add ops/loop.py ops/__init__.py
git commit -m "feat: add create_loop main function"
```

---

## Task 8: Final Testing + Integration Test

**Files:**
- Test with real video files

**Step 1: Run full integration test**

```bash
# Test with existing video
python cli.py test-fps.webm test-loop.webm loop --method auto --first-frames 5 --last-frames 5

# Verify output
ls -la test-loop.webm
```

**Step 2: Run all tests**

```bash
pytest tests/ -v
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: complete video looper feature"
```

---

## Summary

Total tasks: 8

- Task 1: Rename project (5 steps)
- Task 2: Add loop to ops registry (4 steps)
- Task 3: Frame extraction (5 steps)
- Task 4: Similarity detection (5 steps)
- Task 5: Match point finding (5 steps)
- Task 6: Loop methods (5 steps)
- Task 7: Main function + CLI (4 steps)
- Task 8: Integration test (3 steps)

**Plan complete and saved to `docs/plans/2026-03-04-framer-loop-design.md`. Two execution options:**

1. **Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration
2. **Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
