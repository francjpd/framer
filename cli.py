#!/usr/bin/env python3
"""
CLI tool for video processing with operations like background removal, FPS boost, etc.

Usage:
    python cli.py [operation] <input> <output> [options...]

Operations:
    remove-bg - Remove background with alpha channel
    fps-boost - Increase video frame rate
    loop - Create seamless infinite loops
    resize - Resize or scale a video
    trim - Trim a specific time segment
    export - Export to optimized web formats (gif, webm, mp4)
    recolor - Replace a specific color with a new color
    glow - Add a soft glow behind an object with a transparent background
    outline - Add a solid outline to a video with a transparent background
    deform - Deform a still image with a rig/bones puppet warp
"""

import sys
import os
import json
from pathlib import Path
from typing import Optional, Annotated
import typer
from rich import print

from core.utils import parse_color
from ops.remove_bg import remove_bg as op_remove_bg
from ops.fps_boost import boost_fps as op_boost_fps
from ops.loop import create_loop as op_loop
from ops.resize import resize_video as op_resize
from ops.trim import trim_video as op_trim
from ops.export import export_web as op_export
from ops.recolor import recolor_video as op_recolor
from ops.glow import add_glow as op_glow
from ops.outline import add_outline as op_outline
from ops.deform import deform_video as op_deform

app = typer.Typer(
    help="Video processing CLI with composable operations",
    add_completion=False,
    no_args_is_help=True
)

def get_default_workers() -> int:
    return max(1, int((os.cpu_count() or 4) * 2 / 3))

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
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
    config: Annotated[Optional[str], typer.Option("--config", help="Path to JSON config file")] = None,
):
    kwargs = {
        "color": list(parse_color(color)) if color else None,
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
        "progress": progress,
        "workers": workers
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
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
    config: Annotated[Optional[str], typer.Option("--config", help="Path to JSON config file")] = None,
):
    kwargs = {"to": to, "progress": progress, "workers": workers}
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
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
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
        "progress": progress,
        "workers": workers
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


@app.command(name="resize", help="Resize or scale a video")
def resize_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    width: Annotated[int, typer.Option("-W", "--width", help="Target width (-1 to keep aspect ratio)")] = -1,
    height: Annotated[int, typer.Option("-H", "--height", help="Target height (-1 to keep aspect ratio)")] = -1,
    pad: Annotated[bool, typer.Option(help="Pad with transparency if aspect ratio changes")] = False,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress")] = False,
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
):
    try:
        result = op_resize(input_path=input_path, output_path=output_path, width=width, height=height, pad=pad, workers=workers, progress=progress)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="trim", help="Trim a segment of a video")
def trim_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    start: Annotated[Optional[float], typer.Option("-s", "--start", help="Start time in seconds")] = None,
    end: Annotated[Optional[float], typer.Option("-e", "--end", help="End time in seconds")] = None,
    duration: Annotated[Optional[float], typer.Option("-d", "--duration", help="Duration in seconds")] = None,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress")] = False,
):
    try:
        result = op_trim(input_path=input_path, output_path=output_path, start=start, end=end, duration=duration, progress=progress)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="export", help="Export to optimized web formats (gif, webm, mp4)")
def export_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_dir: Annotated[str, typer.Argument(help="Output directory")],
    format: Annotated[str, typer.Option("-f", "--format", help="Format: webm, mp4, gif, all")] = "all",
    fps: Annotated[int, typer.Option(help="Change framerate for export")] = -1,
    scale: Annotated[int, typer.Option(help="Scale width (keeps aspect ratio)")] = -1,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress")] = False,
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
):
    try:
        result = op_export(input_path=input_path, output_dir=output_dir, format=format, fps=fps, scale=scale, workers=workers, progress=progress)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="recolor", help="Replace a specific color with a new color")
def recolor_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    target: Annotated[str, typer.Option("-t", "--target", help="Target color to replace (hex or BGR)")],
    new_color: Annotated[str, typer.Option("-n", "--new-color", help="New color to apply (hex or BGR)")],
    tolerance: Annotated[int, typer.Option(help="Color matching tolerance")] = 30,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress bar")] = False,
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
):
    try:
        result = op_recolor(input_path=input_path, output_path=output_path, target=target, new_color=new_color, tolerance=tolerance, workers=workers, progress=progress)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="glow", help="Add a soft glow behind an object with a transparent background")
def glow_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    color: Annotated[str, typer.Option("-c", "--color", help="Glow color (hex or BGR)")] = "#FFFFFF",
    radius: Annotated[int, typer.Option("-r", "--radius", help="Blur radius size")] = 15,
    intensity: Annotated[float, typer.Option("-i", "--intensity", help="Brightness multiplier")] = 1.0,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress bar")] = False,
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
):
    try:
        result = op_glow(input_path=input_path, output_path=output_path, color=color, radius=radius, intensity=intensity, workers=workers, progress=progress)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)

@app.command(name="outline", help="Add a solid outline to a video with a transparent background")
def outline_cmd(
    input_path: Annotated[str, typer.Argument(help="Input video file")],
    output_path: Annotated[str, typer.Argument(help="Output video file")],
    color: Annotated[str, typer.Option("-c", "--color", help="Outline color (hex or BGR)")] = "#FFFFFF",
    thickness: Annotated[int, typer.Option("-t", "--thickness", help="Outline thickness in pixels")] = 5,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress bar")] = False,
    workers: Annotated[int, typer.Option("-w", "--workers", help="Number of worker threads")] = get_default_workers(),
):
    try:
        result = op_outline(input_path=input_path, output_path=output_path, color=color, thickness=thickness, workers=workers, progress=progress)
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)


@app.command(name="deform", help="Deform a still image with a rig/bones puppet warp")
def deform_cmd(
    input_path: Annotated[str, typer.Argument(help="Input still image (or video, first frame)")],
    output_path: Annotated[str, typer.Argument(help="Output video (.webm/.mov/.gif) or image (.png) for one frame")],
    rig: Annotated[str, typer.Option("-r", "--rig", help="Path to a framer.rig JSON document")],
    start_frame: Annotated[int, typer.Option("--start-frame", help="First frame of the range")] = 0,
    end_frame: Annotated[Optional[int], typer.Option("--end-frame", help="Last frame of the range (default: rig.duration.frames)")] = None,
    fps: Annotated[Optional[float], typer.Option("--fps", help="Output fps (default: rig.duration.fps)")] = None,
    iterations: Annotated[int, typer.Option("-i", "--iterations", help="Fixed-point inversion iterations")] = 5,
    weights: Annotated[Optional[str], typer.Option("--weights", help="Optional dense-weight .npz cache path")] = None,
    radius_scale: Annotated[Optional[float], typer.Option("--radius-scale", help="Scale all bone influence radii")] = None,
    progress: Annotated[bool, typer.Option("-p", "--progress", help="Show progress")] = False,
):
    try:
        result = op_deform(
            input_path=input_path,
            output_path=output_path,
            rig=rig,
            start_frame=start_frame,
            end_frame=end_frame,
            fps=fps,
            iterations=iterations,
            weights=weights,
            radius_scale=radius_scale,
            progress=progress,
        )
        handle_result(result)
    except Exception as e:
        print(f"\n[bold red]❌ Error:[/bold red] {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    app()
