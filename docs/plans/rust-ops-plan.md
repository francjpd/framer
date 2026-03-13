# Rust Video Operations Migration Plan

## Overview

Port video processing operations from Python to Rust. Focus on FFmpeg-based solutions that can be **bundled into the executable** - no system dependencies required for users.

## Why FFmpeg-Only?

| Approach | Bundled in Release | Complexity |
|----------|-------------------|------------|
| FFmpeg filters | ✅ Static binaries | Low |
| OpenCV | ❌ System libraries | High |
| Python | ❌ Requires Python | Medium |

**Decision**: Use FFmpeg CLI via Rust `std::process::Command` (same pattern we have now but cleaner) or `ffmpeg-next` crate for embedded FFmpeg.

---

## Rust Libraries

```toml
[dependencies]
rustler = "0.37"
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Optional - for more control (adds build complexity)
# ffmpeg-next = "7"
```

**Note**: We'll use `std::process::Command` calling bundled FFmpeg binaries initially - cleaner and easier to maintain. FFmpeg can be packaged with the release.

---

## Operations to Port

### 1. FPS Boost (`ops/fps_boost.py`)

**Current**: FFmpeg minterpolate filter via subprocess

**Rust**: Same FFmpeg filter, cleaner封装

```rust
pub fn boost_fps(input: &str, output: &str, target_fps: u32) -> Result<String, Error>
```

**FFmpeg filters used**:
- `minterpolate=fps={target}:mi_mode=mci:mc_mode=aobmc`
- Fallback: `fps={target}` for simple framerate conversion

**Options to implement**:
- `--to` - Target FPS (default: 60)
- Alpha channel preservation (yuva420p output)
- Format selection (webm → libvpx-vp9, mov → qtrle, mp4 → libx264)

---

### 2. Background Removal (`ops/remove_bg.py`, `core/bg_removal.py`)

**Current**: OpenCV color-based detection + morphological ops

**Rust/FFmpeg approach**:

```rust
pub fn remove_bg(
    input: &str, 
    output: &str, 
    color: &str,      // "0,255,0" or "#00FF00"
    tolerance: u32,   // Color tolerance
    edges: u32,      // Soft edge size
    method: &str,   // "color", "motion", "combined"
) -> Result<String, Error>
```

**FFmpeg filters used**:
- `colorkey=color=0x00FF00:similarity=0.3` - Color-based keying
- `chromakey` - Chroma key for green screen
- `format=yuva420p` - Add alpha channel
- `gblur=sigma=3` - Soft edges via gaussian blur
- `negate` - For motion detection

**Complex cases** (may need frame-by-frame processing):
- Adaptive background (per-frame color detection)
- Refinement pass
- Motion detection

---

### 3. Loop Operations (`ops/loop.py`)

8 methods to implement:

| Method | Description | FFmpeg Approach |
|--------|-------------|-----------------|
| `pingpong` | Forward then backward | Duplicate frames in reverse |
| `morph` | Optical flow warping | Complex - may need OpenCV |
| `periodic` | Auto-detect cycles | Frame analysis + trim |
| `hold` | Freeze at transition | Duplicate end frames |
| `fade` | Fade to color/transparent | `fade` filter |
| `blend` | Blend modes | `blend` filter |
| `reverse` | Full reverse | `reverse` filter |
| `speedramp` | Speed adjustment | `setpts` filter |
| `auto` | Analyze and pick | Analysis first, then method |

```rust
pub fn create_loop(
    input: &str,
    output: &str,
    method: &str,           // "pingpong", "morph", etc.
    fade_color: Option<&str>,
    fade_frames: Option<u32>,
    morph_steps: Option<u32>,
    hold_frames: Option<u32>,
    blend_mode: Option<&str>,
    ramp_factor: Option<f64>,
    analyze_only: bool,
) -> Result<String, Error>
```

---

## NIF Functions to Implement

```rust
// Video Info
#[rustler::nif]
pub fn get_video_info(path: String) -> Result<String, Error>

// FPS Boost
#[rustler::nif]
pub fn boost_fps(input: String, output: String, target_fps: u32) -> Result<String, Error>

// Background Removal
#[rustler::nif]
pub fn remove_bg(
    input: String, 
    output: String, 
    color: String,
    tolerance: u32,
    edges: u32,
    method: String,
) -> Result<String, Error>

// Loop Operations
#[rustler::nif]
pub fn create_loop(
    input: String,
    output: String,
    method: String,
    fade_color: Option<String>,
    fade_frames: Option<u32>,
    morph_steps: Option<u32>,
    hold_frames: Option<u32>,
    blend_mode: Option<String>,
    ramp_factor: Option<f64>,
) -> Result<String, Error>

// General Filter
#[rustler::nif]
pub fn apply_filter(input: String, output: String, filter: String) -> Result<String, Error>
```

---

## Testing Strategy

### Phase 1: Capture Baseline

Run existing Python tests and capture outputs as golden files:

```bash
# FPS Boost tests
pytest tests/ -k "fps" -v

# Background removal tests  
pytest tests/test_ops_remove_bg.py -v

# Loop tests
pytest tests/test_loop.py -v
```

### Phase 2: Implement Rust

Implement each operation in Rust, keeping Python as reference.

### Phase 3: Validate

Run same inputs through Rust implementation, compare outputs:

| Test Type | Validation |
|-----------|------------|
| Unit tests | Compare frame counts, metadata |
| Golden tests | Compare output frame pixels |
| Integration | Full pipeline test |

---

## Existing Tests (must continue working)

| Test File | Tests |
|-----------|-------|
| `tests/test_ops_remove_bg.py` | Background removal config, color parsing |
| `tests/test_loop.py` | 8 loop methods + auto analysis |
| `tests/test_ops_resize.py` | Resize operation |
| `tests/test_ops_trim.py` | Trim operation |
| `tests/test_ops_outline.py` | Outline operation |
| `tests/test_ops_glow.py` | Glow operation |
| `tests/test_ops_recolor.py` | Recolor operation |

---

## Implementation Steps

### Step 1: Set Up Rust Module
- Create `native/framer_rust/src/ops/` directory
- Add operations module structure

### Step 2: FPS Boost
- Implement frame rate detection
- Implement minterpolate filter
- Handle alpha channel
- Add CLI wrapper

### Step 3: Background Removal
- Implement color keying
- Add morphological operations
- Handle edge softening
- Test with existing videos

### Step 4: Loop Operations
- Implement each method
- Add auto-analysis
- Validate against Python outputs

### Step 5: Integration
- Wire NIFs to Elixir CLI
- Run full test suite
- Compare outputs

---

## Bundling FFmpeg

For the final release, FFmpeg binaries can be:

1. **Downloaded on first run** - `mix hex` or similar
2. **Pre-bundled** - Include in release archive
3. **Static build** - Compile FFmpeg statically

```elixir
# In release config, include FFmpeg binaries
def releases do
  [
    framer: [
      include_executables_for: [:unix],
      # Add FFmpeg binaries to release
    ]
  ]
end
```

---

## Success Criteria

- [ ] FPS boost works with all formats (webm, mov, mp4)
- [ ] Background removal produces clean alpha channel
- [ ] All 8 loop methods produce correct output
- [ ] Auto-analysis selects appropriate method
- [ ] Output matches Python implementation (golden tests)
- [ ] All existing tests pass
- [ ] Single executable release (FFmpeg bundled)
- [ ] Performance comparable to Python

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| FFmpeg not available | Runtime error | Bundle FFmpeg in release |
| Complex morph loop | Hard to implement | Use simpler method, add later |
| Memory usage | Crash | Process in chunks |
