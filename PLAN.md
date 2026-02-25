# Auto Color Range Generation - Implementation Plan

## Problem

The current background removal implementation uses a single color with a fixed tolerance. This doesn't work well for:
- Green/blue screens with lighting variations
- Non-uniform backgrounds
- Colors that shift slightly across the video

## Solution

Auto-generate multiple color ranges from a single input color to capture background variations.

## Input

- **User provides:** RGB(74, 101, 73) → BGR [73, 101, 74]
- **Code generates:** Multiple color ranges covering variations

## Implementation

### 1. Modify `remove_bg_alpha.py`

Add new function `generate_color_ranges()`:

```python
def generate_color_ranges(base_bgr_color, num_ranges=5, base_tolerance=25):
    """
    Generate multiple color ranges from a base color.
    
    Args:
        base_bgr_color: Base color in BGR format [B, G, R]
        num_ranges: Number of variations to generate
        base_tolerance: Base tolerance for each range
    
    Returns:
        List of color range dicts: [{"color": [...], "tolerance": XX}, ...]
    """
    ranges = []
    
    # Base color
    ranges.append({
        "color": base_bgr_color,
        "tolerance": base_tolerance
    })
    
    # Generate variations
    b, g, r = base_bgr_color
    
    variations = [
        ("lighter", 15),   # +15 to all channels
        ("darker", 15),    # -15 from all channels  
        ("high_green", 20), # +20 to green channel
        ("low_green", 20),  # -20 from green channel
        ("brighter", 25),   # +25 to all channels
    ]
    
    for name, variation in variations[:num_ranges-1]:
        new_b = max(0, min(255, b + variation))
        new_g = max(0, min(255, g + variation))
        new_r = max(0, min(255, r + variation))
        
        ranges.append({
            "color": [new_b, new_g, new_r],
            "tolerance": base_tolerance + 5
        })
    
    return ranges
```

### 2. Modify `bgremover.py`

Update `VideoBackgroundRemover` class:

- Add method `add_auto_color_ranges(base_color, num_ranges=5, tolerance=25)`
- Update `process_frame()` to handle multiple color ranges with OR logic
- Ensure mask combines all ranges correctly

### 3. Modify `remove_bg_alpha.py`

Update `remove_background_with_alpha()` function:

- Add parameter `auto_ranges=True`
- When enabled, call `generate_color_ranges()` 
- Pass all ranges to the processor

### 4. Modify `agent_wrapper.py`

Update `remove_video_background()` function:

- Add parameter `auto_ranges=True` (default: True)
- When enabled, generate ranges automatically
- Pass to underlying CLI tool

### 5. Modify CLI `remove_bg_alpha.py`

Add CLI argument:

```bash
--auto-ranges / --no-auto-ranges
```

Default: enabled

## Usage After Changes

### Python

```python
from agent_wrapper import remove_video_background

# Simple - auto-generates ranges from one color
result = remove_video_background(
    input_path="video.mp4",
    output_path="output",
    background_color=[73, 101, 74],  # RGB(74,101,73) → BGR
    tolerance=25,
)

# With custom number of ranges
result = remove_video_background(
    input_path="video.mp4", 
    output_path="output",
    background_color=[73, 101, 74],
    tolerance=25,
    auto_ranges=True,
    num_ranges=7,  # More variations
)
```

### CLI

```bash
# Auto ranges (default)
python remove_bg_alpha.py input.mp4 output -c "73,101,74" -t 25

# Disable auto ranges
python remove_bg_alpha.py input.mp4 output -c "73,101,74" -t 25 --no-auto-ranges
```

## Files to Modify

| File | Changes |
|------|---------|
| `bgremover.py` | Add `add_auto_color_ranges()` method |
| `remove_bg_alpha.py` | Add `generate_color_ranges()`, integrate with processing |
| `agent_wrapper.py` | Add `auto_ranges` parameter, pass to CLI |
| `SKILL.md` | Document new auto-range feature |

## Testing

1. Test with octopus-green.mp4 using RGB(74, 101, 73)
2. Verify background is fully removed
3. Verify subject (octopus) is not cut
4. Compare output quality with different `num_ranges` values

## Notes

- HSV-based range generation could be added later for even better handling
- Current implementation uses BGR variations (simpler, more predictable)
- Default 5 ranges should cover most green screen scenarios
