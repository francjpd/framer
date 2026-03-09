"""
Video utilities for frame streaming and FFmpeg integration.
"""

import subprocess
import numpy as np
from pathlib import Path
from typing import Optional


def get_output_format(output_path: str, format_flag: Optional[str] = None) -> str:
    """Determine output format from path extension or flag."""
    if format_flag is not None:
        return format_flag.lower()

    ext = Path(output_path).suffix.lower()
    if ext == ".webm":
        return "webm"
    elif ext == ".gif":
        return "gif"
    elif ext == ".mp4":
        return "mp4"
    else:
        return "mov"


class VideoStreamWriter:
    """
    Writes video frames directly to FFmpeg via stdin pipe.
    Avoids saving intermediate PNGs to disk.
    """

    def __init__(
        self,
        output_path: str,
        fps: float,
        width: int,
        height: int,
        has_alpha: bool = False,
        loop: bool = True,
        workers: int = 1,
    ):
        self.output_path = output_path
        self.fps = fps
        self.width = width
        self.height = height
        self.has_alpha = has_alpha
        self.loop = loop
        self.workers = workers
        self.format = get_output_format(output_path)
        self.process = None
        self._start_process()

    def _start_process(self):
        # Use raw video for fast pipe transmission
        pix_fmt_in = "bgra" if self.has_alpha else "bgr24"
        
        cmd = [
            "ffmpeg",
            "-y",
            "-threads", str(self.workers),
            "-f", "rawvideo",
            "-vcodec", "rawvideo",
            "-s", f"{self.width}x{self.height}",
            "-pix_fmt", pix_fmt_in,
            "-r", str(self.fps),
            "-i", "-",
        ]

        if self.format == "webm":
            cmd.extend([
                "-c:v", "libvpx-vp9",
                "-pix_fmt", "yuva420p" if self.has_alpha else "yuv420p",
                "-auto-alt-ref", "0",
                "-crf", "30",
                "-b:v", "0",
            ])
        elif self.format == "gif":
            # For GIF, we use a complex filter to generate palette and dither on the fly
            cmd.extend([
                "-vf", "split[s0][s1];[s0]palettegen=stats_mode=max[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
            ])
            if self.loop:
                cmd.extend(["-loop", "0"])
            else:
                cmd.extend(["-loop", "1"])
        elif self.format == "mp4":
            cmd.extend([
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-crf", "23"
            ])
        else: # mov or other
            if self.has_alpha:
                cmd.extend(["-c:v", "qtrle"])
            else:
                cmd.extend(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23"])

        cmd.append(self.output_path)
        
        self.process = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE
        )

    def write_frame(self, frame: np.ndarray):
        """Write a BGR or BGRA numpy array frame to the stream."""
        if self.process is None:
            raise RuntimeError("Process not started or already closed")
            
        # Ensure correct shape
        if frame.shape[:2] != (self.height, self.width):
            raise ValueError(f"Frame shape {frame.shape[:2]} does not match initialized dimensions {(self.height, self.width)}")
            
        self.process.stdin.write(frame.tobytes())

    def close(self):
        """Close the stream and wait for FFmpeg to finish encoding."""
        if self.process:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, ValueError):
                pass
                
            stderr_data = b""
            try:
                _, stderr_raw = self.process.communicate()
                if stderr_raw:
                    stderr_data = stderr_raw
            except (BrokenPipeError, ValueError):
                self.process.wait()
                if self.process.stderr and not self.process.stderr.closed:
                    stderr_data = self.process.stderr.read()
                
            if self.process.returncode != 0 and self.process.returncode is not None:
                err_msg = stderr_data.decode('utf-8', errors='replace') if stderr_data else "Unknown FFmpeg error"
                raise RuntimeError(f"FFmpeg error: {err_msg}")
            
            self.process = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is None:
            self.close()
        else:
            if self.process:
                self.process.kill()
