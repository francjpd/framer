# Video Loop Methods Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace current loop.py with 9 new loop methods (pingpong, morph, periodic, hold, fade, blend, reverse, speedramp, auto) with clear "best for" guidance in help text.

**Architecture:** Rewrite ops/loop.py with modular method implementations. Each method is a separate function. Args schema includes method selection and method-specific parameters. Update README with examples.

**Tech Stack:** Python, OpenCV (optical flow), NumPy

---

## Task 1: Write Tests for New Loop Methods

**Files:**
- Test: `tests/test_loop.py` (create)

**Step 1: Create test file**

```python
import pytest
import numpy as np
import sys
sys.path.insert(0, '/home/francjpd/projects/bg-remover')

from ops.loop import (
    create_pingpong_loop,
    create_morph_loop,
    create_periodic_loop,
    create_hold_loop,
    create_fade_loop,
    create_blend_loop,
    create_reverse_loop,
    create_speedramp_loop,
    analyze_best_method,
    parse_fade_color,
)


def test_parse_fade_color_transparent():
    result = parse_fade_color("transparent")
    assert result == (0, 0, 0, 0)


def test_parse_fade_color_hex():
    result = parse_fade_color("#FF0000")
    assert result == (0, 0, 255, 255)


def test_parse_fade_color_bgr():
    result = parse_fade_color("0,255,0")
    assert result == (0, 255, 0, 255)


def test_pingpong_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_pingpong_loop(frames)
    assert len(result) == 20
    assert np.array_equal(result[0], frames[0])
    assert np.array_equal(result[-1], frames[0])


def test_reverse_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_reverse_loop(frames)
    assert len(result) == 20
    assert np.array_equal(result[0], frames[0])
    assert np.array_equal(result[-1], frames[0])


def test_hold_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_hold_loop(frames, hold_frames=2)
    assert len(result) == 12


def test_fade_loop_transparent():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(20)]
    result = create_fade_loop(frames, fade_color="transparent", fade_frames=5)
    assert len(result) == 20


def test_blend_loop_add():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_blend_loop(frames, blend_mode="add")
    assert len(result) == 10


def test_speedramp_loop():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(10)]
    result = create_speedramp_loop(frames, ramp_factor=1.0)
    assert len(result) >= 10


def test_analyze_best_method_returns_dict():
    frames = [np.ones((10, 10, 3), dtype=np.uint8) * i for i in range(20)]
    result = analyze_best_method(frames)
    assert isinstance(result, dict)
    assert "recommended" in result
```

**Step 2: Run tests to verify they fail**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py -v`
Expected: FAIL with "module 'ops.loop' has no attribute..."

**Step 3: Commit**

```bash
cd /home/francjpd/projects/bg-remover
git add tests/test_loop.py
git commit -m "test: add test file for new loop methods"
```

---

## Task 2: Implement Core Helper Functions

**Files:**
- Modify: `ops/loop.py` (add at top of file after imports)

**Step 1: Add helper functions**

Add these functions after imports (around line 15):

```python
def parse_fade_color(color_str: str) -> Tuple[int, int, int, int]:
    """Parse fade color string to RGBA tuple.
    
    Supports:
    - "transparent" -> (0, 0, 0, 0)
    - "#RRGGBB" or "#RGB" -> (R, G, B, 255)
    - "B,G,R" -> (B, G, R, 255)
    """
    if not color_str or color_str.lower() == "transparent":
        return (0, 0, 0, 0)
    
    color_str = color_str.strip()
    
    if color_str.startswith("#"):
        color_str = color_str[1:]
        if len(color_str) == 3:
            r = int(color_str[0] * 2, 16)
            g = int(color_str[1] * 2, 16)
            b = int(color_str[2] * 2, 16)
        elif len(color_str) == 6:
            r = int(color_str[0:2], 16)
            g = int(color_str[2:4], 16)
            b = int(color_str[4:6], 16)
        else:
            raise ValueError(f"Invalid hex color: {color_str}")
        return (r, g, b, 255)
    
    try:
        values = [int(x.strip()) for x in color_str.split(",")]
        if len(values) == 3:
            return (values[2], values[1], values[0], 255)
    except ValueError:
        pass
    
    raise ValueError(f"Invalid color format: {color_str}")


def apply_blend_mode(frame1: np.ndarray, frame2: np.ndarray, mode: str) -> np.ndarray:
    """Apply blend mode between two frames."""
    f1 = frame1.astype(float)
    f2 = frame2.astype(float)
    
    if mode == "add":
        result = np.clip(f1 + f2, 0, 255).astype(np.uint8)
    elif mode == "multiply":
        result = (f1 * f2 / 255).astype(np.uint8)
    elif mode == "screen":
        result = 255 - (255 - f1) * (255 - f2) / 255
        result = np.clip(result, 0, 255).astype(np.uint8)
    elif mode == "overlay":
        result = np.where(f1 < 128, 2 * f1 * f2 / 255, 255 - 2 * (255 - f1) * (255 - f2) / 255)
        result = np.clip(result, 0, 255).astype(np.uint8)
    else:
        result = cv2.addWeighted(frame1, 0.5, frame2, 0.5, 0)
    
    return result


def detect_cycle_period(frames: List[np.ndarray], max_period: int = 120) -> Optional[int]:
    """Auto-detect periodic motion using frame differences.
    
    Returns: Detected cycle period in frames, or None if no clear cycle.
    """
    if len(frames) < 10:
        return None
    
    n = min(len(frames), max_period)
    diffs = []
    
    for i in range(1, n):
        diff = np.mean(np.abs(frames[i].astype(float) - frames[i-1].astype(float)))
        diffs.append(diff)
    
    autocorr = np.correlate(diffs, diffs, mode='full')
    autocorr = autocorr[len(autocorr)//2:]
    
    peaks = []
    for i in range(2, len(autocorr) - 1):
        if autocorr[i] > autocorr[i-1] and autocorr[i] > autocorr[i+1]:
            if autocorr[i] > np.mean(autocorr) * 1.2:
                peaks.append(i)
    
    if peaks:
        return peaks[0]
    return None
```

**Step 2: Run tests**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_parse_fade_color_transparent -v`
Expected: PASS

**Step 3: Commit**

```bash
cd /home/francjpd/projects/bg-remover
git add ops/loop.py
git commit -m "feat(loop): add helper functions for new loop methods"
```

---

## Task 3: Implement Pingpong Method

**Files:**
- Modify: `ops/loop.py` (add function after helper functions)

**Step 1: Add pingpong function**

Add after helper functions:

```python
def create_pingpong_loop(frames: List[np.ndarray]) -> List[np.ndarray]:
    """Create pingpong (boomerang) loop - forward then backward.
    
    Best for: bouncing objects, pendulum, breathing, any reversible motion.
    Plays video forward, then reverses, creating smooth yoyo effect.
    """
    if len(frames) < 2:
        return frames
    
    forward = frames[:]
    backward = frames[:-1][::-1]
    
    return forward + backward
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_pingpong_loop -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add pingpong method"
```

---

## Task 4: Implement Reverse Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add reverse function**

```python
def create_reverse_loop(frames: List[np.ndarray]) -> List[np.ndarray]:
    """Create reverse loop - forward then full reverse.
    
    Best for: reversible motion like water ripples, fire, particles, 
    any motion that looks the same forwards and backwards.
    """
    if len(frames) < 2:
        return frames
    
    forward = frames[:]
    reverse = frames[::-1]
    
    return forward + reverse
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_reverse_loop -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add reverse method"
```

---

## Task 5: Implement Hold Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add hold function**

```python
def create_hold_loop(frames: List[np.ndarray], hold_frames: int = 2) -> List[np.ndarray]:
    """Create hold loop - freeze briefly at transition point.
    
    Best for: videos with natural pauses or holds in the motion.
    Freezes the transition frame for a few frames to mask the seam.
    
    Args:
        frames: Input video frames
        hold_frames: Number of frames to hold (default: 2)
    """
    if len(frames) < 4 or hold_frames < 1:
        return frames
    
    start_frame = frames[0]
    end_frame = frames[-1]
    
    result = frames[:]
    
    for _ in range(hold_frames):
        result.append(end_frame)
    
    result.append(start_frame)
    
    return result
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_hold_loop -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add hold method"
```

---

## Task 6: Implement Fade Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add fade function**

```python
def create_fade_loop(
    frames: List[np.ndarray],
    fade_color: str = "transparent",
    fade_frames: int = 10,
    fade_type: str = "both"
) -> List[np.ndarray]:
    """Create fade loop - fade out/in at transition point.
    
    Best for: when nothing else works - masks seams completely with fade.
    Supports transparent (for alpha videos) or custom colors.
    
    Args:
        frames: Input video frames
        fade_color: "transparent", hex (#RRGGBB), or BGR (B,G,R)
        fade_frames: Number of frames for fade (default: 10)
        fade_type: "in", "out", or "both" (default: "both")
    """
    if len(frames) < fade_frames * 2:
        return frames
    
    color = parse_fade_color(fade_color)
    fade_frames = min(fade_frames, len(frames) // 4)
    
    result = []
    n = len(frames)
    
    fade_frame = np.full((frames[0].shape[0], frames[0].shape[1], 4), color, dtype=np.uint8)
    if len(frames[0].shape) == 3 and frames[0].shape[2] == 3:
        fade_frame = fade_frame[:, :, :3]
    
    for i in range(n):
        frame = frames[i]
        
        if fade_type in ("out", "both"):
            fade_out_start = n - fade_frames * 2
            if i >= fade_out_start:
                alpha = (i - fade_out_start) / fade_frames
                alpha = min(1.0, alpha)
                frame = cv2.addWeighted(frame, 1 - alpha, fade_frame, alpha, 0)
        
        if fade_type in ("in", "both"):
            if i < fade_frames * 2:
                alpha = 1 - (i / fade_frames)
                alpha = max(0, alpha)
                frame = cv2.addWeighted(frame, 1 - alpha, fade_frame, alpha, 0)
        
        result.append(frame)
    
    return result
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_fade_loop_transparent -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add fade method with transparent support"
```

---

## Task 7: Implement Blend Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add blend function**

```python
def create_blend_loop(
    frames: List[np.ndarray],
    blend_mode: str = "add",
    blend_frames: int = 5
) -> List[np.ndarray]:
    """Create blend loop - creative blend between end and start.
    
    Best for: artistic effects, creative transitions.
    Uses blend modes: add, multiply, screen, overlay.
    
    Args:
        frames: Input video frames
        blend_mode: add, multiply, screen, or overlay
        blend_frames: Frames to blend at transition (default: 5)
    """
    if len(frames) < blend_frames * 2:
        return frames
    
    result = frames[:-blend_frames]
    
    first_frames = frames[:blend_frames]
    last_frames = frames[-blend_frames:][::-1]
    
    for i in range(blend_frames):
        w = (i + 1) / (blend_frames + 1)
        blended = apply_blend_mode(last_frames[i], first_frames[i], blend_mode)
        result.append(blended)
    
    result.extend(frames[blend_frames:])
    
    return result
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_blend_loop_add -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add blend method"
```

---

## Task 8: Implement Speedramp Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add speedramp function**

```python
def create_speedramp_loop(
    frames: List[np.ndarray],
    ramp_factor: float = 1.0
) -> List[np.ndarray]:
    """Create speedramp loop - adjust playback speed at transition.
    
    Best for: when loop points almost match but need slight speed adjustment.
    Slightly speeds up or slows down to make endpoints align.
    
    Args:
        frames: Input video frames
        ramp_factor: Speed multiplier 0.8-1.2 (default: 1.0)
    """
    if len(frames) < 4 or ramp_factor == 1.0:
        return frames
    
    ramp_factor = max(0.5, min(2.0, ramp_factor))
    
    result = frames[:]
    
    target_len = int(len(frames) * ramp_factor)
    if target_len != len(frames):
        indices = np.linspace(0, len(frames) - 1, target_len)
        result = [frames[int(i)] for i in indices]
    
    return result
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_speedramp_loop -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add speedramp method"
```

---

## Task 9: Implement Morph Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add morph function**

```python
def create_morph_loop(
    frames: List[np.ndarray],
    morph_steps: int = 10
) -> List[np.ndarray]:
    """Create morph loop - multiple warp steps between end and start.
    
    Best for: complex motion where simple interpolation fails.
    Uses optical flow to warp frames gradually from end to start.
    
    Args:
        frames: Input video frames
        morph_steps: Number of warp steps (default: 10)
    """
    if len(frames) < 10 or morph_steps <= 0:
        return frames
    
    end_frame = frames[-1]
    start_frame = frames[0]
    
    gray_end = cv2.cvtColor(end_frame, cv2.COLOR_BGR2GRAY)
    gray_start = cv2.cvtColor(start_frame, cv2.COLOR_BGR2GRAY)
    
    flow = cv2.calcOpticalFlowFarneback(
        gray_end, gray_start, None, 0.5, 3, 15, 3, 5, 1.2, 0
    )
    
    h, w = gray_end.shape
    morphed = []
    
    for i in range(1, morph_steps + 1):
        t = i / (morph_steps + 1)
        
        flow_map = flow * t
        x, y = np.meshgrid(np.arange(w), np.arange(h))
        map_x = (x + flow_map[..., 0]).astype(np.float32)
        map_y = (y + flow_map[..., 1]).astype(np.float32)
        
        warped = cv2.remap(end_frame, map_x, map_y, cv2.INTER_LINEAR)
        result = cv2.addWeighted(warped, 1 - t, start_frame, t, 0)
        morphed.append(result)
    
    return frames + morphed
```

**Step 2: Run test (basic import check)**

Run: `cd /home/francjpd/projects/bg-remover && python -c "from ops.loop import create_morph_loop; print('OK')"`
Expected: OK

**Step 3: Commit**

```bash
git commit -m "feat(loop): add morph method"
```

---

## Task 10: Implement Periodic Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add periodic function**

```python
def create_periodic_loop(
    frames: List[np.ndarray],
    cycle_frames: Optional[int] = None
) -> List[np.ndarray]:
    """Create periodic loop - loop at natural cycle points.
    
    Best for: walking, running, waves - any rhythmic/repetitive motion.
    Auto-detects cycle period or uses specified cycle length.
    
    Args:
        frames: Input video frames
        cycle_frames: Manual cycle length (auto-detect if None)
    """
    if len(frames) < 10:
        return frames
    
    if cycle_frames is None:
        cycle_frames = detect_cycle_period(frames)
    
    if cycle_frames is None or cycle_frames >= len(frames):
        cycle_frames = len(frames) // 2
    
    cycle_frames = max(1, min(cycle_frames, len(frames) - 1))
    
    return frames[:cycle_frames]
```

**Step 2: Run test (basic import check)**

Run: `cd /home/francjpd/projects/bg-remover && python -c "from ops.loop import create_periodic_loop; print('OK')"`
Expected: OK

**Step 3: Commit**

```bash
git commit -m "feat(loop): add periodic method with auto-detection"
```

---

## Task 11: Implement Auto/Analyze Method

**Files:**
- Modify: `ops/loop.py`

**Step 1: Add analyze function**

```python
def analyze_best_method(frames: List[np.ndarray]) -> Dict[str, Any]:
    """Analyze video and recommend best loop method.
    
    Returns dict with:
    - recommended: best method name
    - alternatives: list of methods that could work
    - analysis: dict with motion metrics
    """
    if len(frames) < 10:
        return {"recommended": "hold", "alternatives": ["hold"], "analysis": {}}
    
    first_frame = frames[0]
    last_frame = frames[-1]
    
    diff_first_last = np.mean(np.abs(first_frame.astype(float) - last_frame.astype(float)))
    
    motion_scores = []
    for i in range(1, min(30, len(frames))):
        diff = np.mean(np.abs(frames[i].astype(float) - frames[i-1].astype(float)))
        motion_scores.append(diff)
    
    avg_motion = np.mean(motion_scores) if motion_scores else 0
    
    cycle = detect_cycle_period(frames)
    
    analysis = {
        "frame_count": len(frames),
        "first_last_diff": float(diff_first_last),
        "avg_motion": float(avg_motion),
        "detected_cycle": cycle,
    }
    
    methods = []
    
    if cycle and cycle < len(frames) * 0.8:
        methods.append(("periodic", 90))
    
    if avg_motion < 20:
        methods.append(("fade", 80))
    elif diff_first_last < 30:
        methods.append(("cut", 85))
    
    methods.append(("pingpong", 70))
    
    if avg_motion > 50:
        methods.append(("morph", 65))
    
    methods.sort(key=lambda x: x[1], reverse=True)
    
    alternatives = [m[0] for m in methods[1:4]]
    recommended = methods[0][0] if methods else "hold"
    
    return {
        "recommended": recommended,
        "alternatives": alternatives,
        "analysis": analysis,
    }
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py::test_analyze_best_method_returns_dict -v`
Expected: PASS

**Step 3: Commit**

```bash
git commit -m "feat(loop): add auto-analyze method"
```

---

## Task 12: Update Main create_loop Function

**Files:**
- Modify: `ops/loop.py` (replace create_loop function)

**Step 1: Replace create_loop function**

Replace the existing `create_loop` function (around line 350):

```python
def create_loop(
    input_path: str,
    output_path: str,
    method: str = "auto",
    fade_color: str = "transparent",
    fade_frames: int = 10,
    fade_type: str = "both",
    morph_steps: int = 10,
    cycle_frames: Optional[int] = None,
    hold_frames: int = 2,
    blend_mode: str = "add",
    blend_frames: int = 5,
    ramp_factor: float = 1.0,
    analyze_only: bool = False,
    progress: bool = False,
) -> Dict[str, Any]:
    """
    Main entry point for loop operation.
    
    Creates seamless infinite loops using various methods.
    
    Methods:
    - pingpong: Forward then backward (best for bouncing/pendulum/breathing)
    - morph: Optical flow warps (best for complex motion)
    - periodic: Auto-detect cycles (best for walking/running/waves)
    - hold: Freeze frames at transition (best for videos with pauses)
    - fade: Fade to color/transparent (best when nothing else works)
    - blend: Creative blend modes (best for artistic effects)
    - reverse: Forward then full reverse (best for reversible motion)
    - speedramp: Speed adjustment (best when endpoints almost match)
    - auto: Analyze and pick best method
    
    Args:
        input_path: Input video file
        output_path: Output video file
        method: Loop method (default: auto)
        fade_color: Color for fade: "transparent", hex (#RRGGBB), or BGR (default: transparent)
        fade_frames: Frames for fade transition (default: 10)
        fade_type: "in", "out", or "both" (default: both)
        morph_steps: Warp steps for morph (default: 10)
        cycle_frames: Manual cycle length for periodic (auto-detect if None)
        hold_frames: Frames to hold for hold method (default: 2)
        blend_mode: Blend mode: add, multiply, screen, overlay (default: add)
        blend_frames: Frames to blend (default: 5)
        ramp_factor: Speed multiplier for speedramp 0.8-1.2 (default: 1.0)
        analyze_only: Just analyze, don't process (default: False)
        progress: Show progress (default: False)
    """
    result: Dict[str, Any] = {"success": False, "output_path": None, "error": None}

    try:
        all_frames = extract_all_frames(input_path, show_progress=progress)

        if len(all_frames) < 4:
            result["error"] = "Video too short for looping (minimum 4 frames)"
            return result

        cap = cv2.VideoCapture(input_path)
        fps = 30.0
        if cap.isOpened():
            fps = cap.get(cv2.CAP_PROP_FPS)
            cap.release()

        if method == "auto":
            analysis = analyze_best_method(all_frames)
            if analyze_only:
                result["success"] = True
                result["analysis"] = analysis
                return result
            method = analysis["recommended"]

        if method == "pingpong":
            looped = create_pingpong_loop(all_frames)
        elif method == "morph":
            looped = create_morph_loop(all_frames, morph_steps)
        elif method == "periodic":
            looped = create_periodic_loop(all_frames, cycle_frames)
        elif method == "hold":
            looped = create_hold_loop(all_frames, hold_frames)
        elif method == "fade":
            looped = create_fade_loop(all_frames, fade_color, fade_frames, fade_type)
        elif method == "blend":
            looped = create_blend_loop(all_frames, blend_mode, blend_frames)
        elif method == "reverse":
            looped = create_reverse_loop(all_frames)
        elif method == "speedramp":
            looped = create_speedramp_loop(all_frames, ramp_factor)
        else:
            looped = create_pingpong_loop(all_frames)

        encode_video(looped, output_path, fps)

        result["success"] = True
        result["output_path"] = output_path

    except Exception as e:
        result["error"] = str(e)

    return result
```

**Step 2: Run test**

Run: `cd /home/francjpd/projects/bg-remover && python -c "from ops.loop import create_loop; print('OK')"`
Expected: OK

**Step 3: Commit**

```bash
git commit -m "refactor(loop): update create_loop with new methods"
```

---

## Task 13: Update register_operation Args Schema

**Files:**
- Modify: `ops/loop.py` (update register_operation at bottom)

**Step 1: Replace args_schema**

Replace the register_operation call (around line 435):

```python
register_operation(
    "loop",
    create_loop,
    {
        "method": {
            "type": "string",
            "default": "auto",
            "description": "Loop method: pingpong, morph, periodic, hold, fade, blend, reverse, speedramp, auto (default: auto)",
        },
        "fade_color": {
            "type": "string",
            "default": "transparent",
            "description": "Fade color: 'transparent', hex (#RRGGBB), or BGR (0,255,0) (best for fade method)",
        },
        "fade_frames": {
            "type": "int",
            "default": 10,
            "description": "Number of frames for fade transition (best for fade method)",
        },
        "fade_type": {
            "type": "string",
            "default": "both",
            "description": "Fade type: in, out, or both (best for fade method)",
        },
        "morph_steps": {
            "type": "int",
            "default": 10,
            "description": "Number of warp steps for morph transition (best for morph method)",
        },
        "cycle_frames": {
            "type": "int",
            "default": None,
            "description": "Manual cycle length for periodic method (auto-detect if not set, best for periodic)",
        },
        "hold_frames": {
            "type": "int",
            "default": 2,
            "description": "Number of frames to freeze at transition (best for hold method)",
        },
        "blend_mode": {
            "type": "string",
            "default": "add",
            "description": "Blend mode: add, multiply, screen, overlay (best for blend method)",
        },
        "ramp_factor": {
            "type": "float",
            "default": 1.0,
            "description": "Speed multiplier 0.8-1.2 for speedramp (best for speedramp method)",
        },
        "analyze_only": {
            "type": "bool",
            "default": False,
            "description": "Just analyze and report best method, don't process video",
        },
    },
    description="Create seamless infinite video loops with various methods",
)
```

**Step 2: Verify CLI works**

Run: `cd /home/francjpd/projects/bg-remover && python cli.py --help`
Expected: Shows loop operation

**Step 3: Commit**

```bash
git commit -m "feat(loop): update args schema with new parameters"
```

---

## Task 14: Update README with New Examples

**Files:**
- Modify: `README.md`

**Step 1: Replace loop section**

Replace the loop section (lines 64-88) with:

```markdown
### `loop`
Create seamless infinite video loops with various methods.

**Which method to use:**

| Method | Best For | Example |
|--------|----------|---------|
| `pingpong` | Bouncing objects, pendulum, breathing | `python cli.py input.webm output.webm loop --method pingpong` |
| `morph` | Complex motion, fluid dynamics | `python cli.py input.webm output.webm loop --method morph --morph-steps 15` |
| `periodic` | Walking, running, waves, rhythmic motion | `python cli.py input.webm output.webm loop --method periodic` |
| `hold` | Videos with natural pauses/holds | `python cli.py input.webm output.webm loop --method hold --hold-frames 3` |
| `fade` | When nothing else works | `python cli.py input.webm output.webm loop --method fade --fade-color transparent` |
| `blend` | Creative transitions | `python cli.py input.webm output.webm loop --method blend --blend-mode add` |
| `reverse` | Water ripples, fire, particles | `python cli.py input.webm output.webm loop --method reverse` |
| `speedramp` | Endpoints almost match, need speed tweak | `python cli.py input.webm output.webm loop --method speedramp --ramp-factor 1.1` |
| `auto` | Auto-detect best method | `python cli.py input.webm output.webm loop --method auto` |

**Examples:**

```bash
# Pingpong - forward then backward (best for bouncing/breathing)
python cli.py input.webm output.webm loop --method pingpong

# Morph - optical flow warps (best for complex motion)
python cli.py input.webm output.webm loop --method morph --morph-steps 15

# Periodic - auto-detect walking/running cycles
python cli.py input.webm output.webm loop --method periodic

# Hold - freeze briefly at transition
python cli.py input.webm output.webm loop --method hold --hold-frames 3

# Fade - fade to transparent (best for background-removed videos!)
python cli.py input.webm output.webm loop --method fade --fade-color transparent

# Fade - fade to custom color
python cli.py input.webm output.webm loop --method fade --fade-color "#FF0000"

# Blend - creative add blend
python cli.py input.webm output.webm loop --method blend --blend-mode add

# Reverse - forward then reverse
python cli.py input.webm output.webm loop --method reverse

# Speedramp - slight speed adjustment
python cli.py input.webm output.webm loop --method speedramp --ramp-factor 1.1

# Auto - analyze and pick best method
python cli.py input.webm output.webm loop --method auto

# Just analyze (don't process)
python cli.py input.webm output.webm loop --method auto --analyze-only
```

**Options:**
- `--method` - Loop method (default: auto)
- `--fade-color` - Color for fade: "transparent", hex (#RRGGBB), or BGR (default: transparent)
- `--fade-frames` - Frames for fade (default: 10)
- `--fade-type` - "in", "out", or "both" (default: both)
- `--morph-steps` - Warp steps for morph (default: 10)
- `--cycle-frames` - Manual cycle length for periodic
- `--hold-frames` - Freeze frames for hold (default: 2)
- `--blend-mode` - add, multiply, screen, overlay (default: add)
- `--ramp-factor` - Speed 0.8-1.2 for speedramp (default: 1.0)
- `--analyze-only` - Just analyze, don't process
```

**Step 2: Commit**

```bash
git commit -m "docs: update README with new loop methods and examples"
```

---

## Task 15: Run Full Test Suite

**Files:**
- Test: `tests/test_loop.py`

**Step 1: Run all loop tests**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/test_loop.py -v`
Expected: All PASS

**Step 2: Run existing tests**

Run: `cd /home/francjpd/projects/bg-remover && python -m pytest tests/ -v`
Expected: All PASS

**Step 3: Commit**

```bash
git commit -m "test: run full test suite"
```

---

## Plan Complete

All tasks done. Run final verification:

```bash
cd /home/francjpd/projects/bg-remover
python cli.py --help
python cli.py input.webm output.webm loop --method auto --analyze-only
```
