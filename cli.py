#!/usr/bin/env python3
"""
CLI tool for video processing with operations like background removal, FPS boost, etc.

Usage:
    python cli.py [operation] <input> <output> [options...]

Operations:
    remove-bg - Remove background with alpha channel
    fps-boost - Increase video frame rate
    loop - Create seamless infinite loops
"""

import sys
import json
from pathlib import Path
from typing import Optional, Annotated
import typer
from rich import print

from core.utils import parse_color
from ops.remove_bg import remove_bg as op_remove_bg
from ops.fps_boost import boost_fps as op_boost_fps
from ops.loop import create_loop as op_loop

app = typer.Typer(
    help="Video processing CLI with composable operations",
    add_completion=False,
    no_args_is_help=True
)

def load_config(config_path: str, operation_name: str) -> dict:
    if not config_path:
        return {}
    path = Path(config_path)
    if not path.exists():
        print(f"[red]Error: Config file not found: {config_path}[/red]")
        sys.exit(1)
    try:
        with open(path) as f:
            data = json.load(f)
            return data.get(operation_name, {})
    except Exception as e:
        print(f"[red]Error reading config: {e}[/red]")
        sys.exit(1)

def handle_result(result: dict):
    if result.get("success"):
        print(f"\n[bold green]✅ Success![/bold green] Output: {result['output_path']}")
    else:
        print(f"\n[bold red]❌ Error:[/bold red] {result.get('error', 'Unknown error')}")
        sys.exit(1)

@app.command(name="remove-bg", help="Remove background from video with alpha channel")
def remove_bg_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    color: Annotated[Optional[str], typer.Option("-c", "--color", help="Background color (BGR: '0,255,0', hex: '#00FF00')")] = None,
    tolerance: Annotated[int, typer.Option("-t", "--tolerance", help="Color tolerance")] = 30,
    edges: Annotated[int, typer.Option("-e", "--edges", help="Soft edge size")] = 5,
    auto_ranges: Annotated[bool, typer.Option(help="Auto-generate color ranges")] = True,
    num_ranges: Annotated[int, typer.Option("-n", "--num-ranges", help="Number of auto-generated ranges")] = 5,
    method: Annotated[str, typer.Option("-m", "--method", help="Detection method: color, motion, combined")] = "color",
    motion_frames: Annotated[int, typer.Option("-mf", "--motion-frames", help="Frames for motion detection")] = 30,
    edge_cleanup: Annotated[int, typer.Option("-ec", "--edge-cleanup", help="Edge cleanup pixels")] = 3,
    adaptive_bg: Annotated[bool, typer.Option(help="Adaptive background detection")] = False,
    refine: Annotated[bool, typer.Option("-r", "--refine", help="Enable refinement pass")] = False,
    refine_tolerance: Annotated[int, typer.Option("-rt", "--refine-tolerance", help="Refinement tolerance")] = 45,
    refine_block_size: Annotated[int, typer.Option("-rb", "--refine-block-size", help="Refinement block size")] = 32,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress bar")] = False,
    config: Annotated[Optional[str], typer.Option("--config", help="Path to JSON config file")] = None,
):
    kwargs = {
        "color": parse_color(color) if color else None,
        "tolerance": tolerance,
        "edges": edges,
        "auto_ranges": auto_ranges,
        "num_ranges": num_ranges,
        "method": method,
        "motion_frames": motion_frames,
        "edge_cleanup": edge_cleanup,
        "adaptive_bg": adaptive_bg,
        "refine": refine,
        "refine_tolerance": refine_tolerance,
        "refine_block_size": refine_block_size,
        "progress": progress
    }
    
    if config:
        cfg = load_config(config, "remove-bg")
        kwargs.update({k: v for k, v in cfg.items() if k in kwargs})
        
    try:
        result = op_remove_bg(input_path=input_path, output_path=output_path, **kwargs)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="fps-boost", help="Increase video frame rate to make it smoother")
def fps_boost_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    to: Annotated[int, typer.Option(help="Target FPS")] = 60,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress bar")] = False,
    config: Annotated[Optional[str], typer.Option("--config", help="Path to JSON config file")] = None,
):
    kwargs = {"to": to, "progress": progress}
    if config:
        kwargs.update(load_config(config, "fps-boost"))
        
    try:
        result = op_boost_fps(input_path=input_path, output_path=output_path, **kwargs)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="loop", help="Create seamless infinite video loops with various methods")
def loop_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    method: Annotated[str, typer.Option(help="Loop method: auto, pingpong, morph, periodic, hold, fade, blend, reverse, speedramp")] = "auto",
    fade_color: Annotated[str, typer.Option(help="Fade color")] = "transparent",
    fade_frames: Annotated[int, typer.Option(help="Number of frames for fade transition")] = 10,
    fade_type: Annotated[str, typer.Option(help="Fade type: in, out, both")] = "both",
    morph_steps: Annotated[int, typer.Option(help="Number of warp steps for morph transition")] = 10,
    cycle_frames: Annotated[Optional[int], typer.Option(help="Manual cycle length for periodic method")] = None,
    hold_frames: Annotated[int, typer.Option(help="Number of frames to freeze at transition")] = 2,
    blend_mode: Annotated[str, typer.Option(help="Blend mode: add, multiply, screen, overlay")] = "add",
    ramp_factor: Annotated[float, typer.Option(help="Speed multiplier 0.8-1.2 for speedramp")] = 1.0,
    until: Annotated[Optional[float], typer.Option("-u", "--until", help="Start pingpong from this second (negative means from end)")] = None,
    analyze_only: Annotated[bool, typer.Option(help="Just analyze and report best method, don't process video")] = False,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress bar")] = False,
    config: Annotated[Optional[str], typer.Option("--config", help="Path to JSON config file")] = None,
):
    kwargs = {
        "method": method,
        "fade_color": fade_color,
        "fade_frames": fade_frames,
        "fade_type": fade_type,
        "morph_steps": morph_steps,
        "cycle_frames": cycle_frames,
        "hold_frames": hold_frames,
        "blend_mode": blend_mode,
        "ramp_factor": ramp_factor,
        "until": until,
        "analyze_only": analyze_only,
        "progress": progress
    }
    
    if config:
        cfg = load_config(config, "loop")
        kwargs.update({k: v for k, v in cfg.items() if k in kwargs})
        
    try:
        result = op_loop(input_path=input_path, output_path=output_path, **kwargs)
        if analyze_only:
            print("[bold blue]Analysis Results:[/bold blue]")
            print(result.get("analysis", {}))
        else:
            handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    app()
