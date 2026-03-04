# Frame - Video Processing CLI

# Implementation Plan

## Vision

A composable CLI tool for video processing operations that can be chained together, inspired by Elixir's functional composition.

## Core Principles

1. **Input/Output First**: `<input> <output> <operation> [options]`
2. **Composable Operations**: Each operation is standalone, can be chained (future)
3. **Config-Driven**: Complex operations via JSON configs
4. **Exclusive Configs**: `--config` flag cannot be used with other arguments

## CLI Structure

```
python cli.py <input> <output> <operation> [options...]
python cli.py <input> <output> <operation> --config config.json
```

## Operations (Phase 1)

### 1. `remove-bg`

**Description**: Remove background from video with alpha channel
**Source**: Based on existing `bgremover.py` functionality
**Arguments**:

- `--color` - Background color (BGR: '0,255,0', hex: '#00FF00')
- `--tolerance` - Color tolerance (default: 30)
- `--edges` - Soft edge size (default: 5)
- `--auto-ranges` - Auto-generate color ranges (default: True)
- `--num-ranges` - Number of auto-generated ranges
- `--method` - Detection method: color, motion, combined
- `--config` - Path to JSON config file (exclusive)

### 2. `fps-boost`

**Description**: Increase video frame rate using FFmpeg minterpolate
**Arguments**:

- `--to` - Target FPS (default: 60)

## Directory Structure

```
frame/
├── cli.py              # Main CLI entry point
├── core/
│   └── __init__.py     # Pipeline executor, operation registry
├── ops/
│   ├── __init__.py     # Operation registry module
│   ├── remove_bg.py    # Background removal operation
│   └── fps_boost.py    # FPS boost operation
├── tests/
└── requirements.txt
```

## Implementation Details

### 1. Core Module (`core/__init__.py`)

- **OperationRegistry**: Global registry for operations
- **Pipeline**: Future pipeline execution (operations chaining)
- **register_operation()**: Decorator for registering operations

### 2. Operation Structure

Each operation is a Python function with signature:

```python
def operation(input_path: str, output_path: str, **kwargs) -> Dict[str, Any]:
    """
    Args:
        input_path: Input video file
        output_path: Output video file
        **kwargs: Operation-specific arguments

    Returns:
        Dict with 'success', 'output_path', 'error'
    """
```

### 3. Config File Format

```json
{
  "bg": {
    "color": "0,255,0",
    "tolerance": 25,
    "edges": 3,
    "method": "color"
  },
  "fps": {
    "to": 60
  }
}
```

- Configs are operation-specific (`bg`, `fps` keys)
- CLI extracts appropriate section for current operation
- Each operation has its own args schema

### 4. CLI Implementation Details

- Argparse with subparsers for operations
- Subcommands use underscores (e.g., `remove_bg`), registry uses hyphens (`remove-bg`)
- Color parsing handles BGR strings and hex codes
- Exclusive config validation: `--config` cannot be used with other args

## Phase 2 (Future Features)

### 1. Pipeline Chaining

```
python cli.py input.mp4 output.webm \
    --then "remove-bg --color 0,255,0" \
    --then "fps-boost --to 60" \
    --then "save output.webm"
```

### 2. Additional Operations

- `speed` - Speed up/slow down video
- `crop` - Crop video dimensions
- `rotate` - Rotate video
- `scale` - Resize video
- `stabilize` - Video stabilization

### 3. Enhanced Configs

- Pipeline configs with operation sequences
- Default profiles for common tasks
- Environment variable support

## Testing Strategy

1. **Unit Tests**: Each operation function
2. **Integration Tests**: CLI with real videos
3. **Config Tests**: Validate config parsing and exclusivity

## Migration from Original

- Keep `bgremover.py` for backward compatibility
- New CLI replaces old one
- Register existing functions as operations

## Usage Examples

### Basic Operations

```bash
# Remove background
python cli.py input.mp4 output.webm remove_bg --color "0,255,0" --tolerance 30
# Boost FPS
python cli.py input.mp4 output.mp4 fps_boost --to 60
```

### With Config

```bash
# Remove background with config
python cli.py input.mp4 output.webm remove_bg --config remove_bg_config.json
# Boost FPS with config
python cli.py input.mp4 output.mp4 fps_boost --config fps_config.json
```

### Error Cases (Should Fail)

```bash
# ERROR: Config exclusive with other args
python cli.py input.mp4 output.webm remove_bg --config config.json --tolerance 30
```

## Configuration Examples

### `remove_bg_config.json`

```json
{
  "bg": {
    "color": "#00FF00",
    "tolerance": 25,
    "edges": 3,
    "method": "color",
    "auto_ranges": true,
    "num_ranges": 3
  }
}
```

### `fps_config.json`

```json
{
  "fps": {
    "to": 48
  }
}
```

## Implementation Checklist

### Phase 1A: Core Structure

- [ ] Create `core/__init__.py` with OperationRegistry
- [ ] Create `ops/__init__.py` with registry imports
- [ ] Refactor `cli.py` with new structure

### Phase 1B: Operations Implementation

- [ ] Create `ops/fps_boost.py` with FFmpeg minterpolate
- [ ] Create `ops/remove_bg.py` wrapping existing functionality
- [ ] Register both operations

### Phase 1C: CLI Implementation

- [ ] Implement subcommand arg parsing
- [ ] Add config loading and validation
- [ ] Add color parsing utilities
- [ ] Test basic operations

### Phase 1D: Testing & Documentation

- [ ] Create example configs
- [ ] Update README with new CLI structure
- [ ] Test with real videos
- [ ] Validate exclusivity rules

## Technical Notes

### Argparse Challenges

- Subcommand names use underscores (`remove_bg`)
- Registry uses hyphens (`remove-bg`)
- Conversion needed between them

### Config Exclusivity

- Argparse provides defaults for all args
- Must compare passed values vs defaults
- Boolean flags need special handling

### Color Parsing

- Accept BGR strings: `"0,255,0"`
- Accept hex: `"#00FF00"`
- Accept lists: `[0, 255, 0]`
- Conversion to OpenCV BGR format

### FFmpeg Integration

- `fps_boost` uses `minterpolate` filter
- Auto-calculate multiplier: target_fps / original_fps
- Fallback to copy if target <= original
  This plan provides the complete blueprint for implementing the composable video processing CLI as designed.
