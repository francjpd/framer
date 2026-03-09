"""
Global engine for parallel frame-by-frame video processing.
"""
import os
import cv2
import math
import tempfile
import subprocess
import multiprocessing as mp
from pathlib import Path
from typing import Callable, Any, Dict, Optional

def _worker_wrapper(args):
    """
    Generic worker that opens a video chunk, applies a user-provided 
    function to each frame, and writes the output.
    """
    (
        worker_id, input_path, start_frame, end_frame, 
        temp_dir, fps, width, height, output_ext,
        process_func, func_kwargs, show_progress
    ) = args

    import cv2
    import os
    from core.video import VideoStreamWriter
    
    cap = cv2.VideoCapture(input_path)
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    
    temp_output = os.path.join(temp_dir, f"part_{worker_id:04d}{output_ext}")
    
    # We always write out as RGBA/BGRA if alpha is involved, but the user function 
    # should return a frame that is (H, W, 4) for alpha, or (H, W, 3) for no alpha.
    writer = VideoStreamWriter(
        output_path=temp_output,
        fps=fps,
        width=width,
        height=height,
        has_alpha=True, # Defaulting to True for safety on operations like remove-bg
        loop=False,
        workers=1 # Individual writers only use 1 thread, the pool handles concurrency
    )

    frames_to_process = end_frame - start_frame
    frames_processed = 0

    while frames_processed < frames_to_process:
        ret, frame = cap.read()
        if not ret:
            break

        # Apply the custom operation to the frame
        processed_frame = process_func(frame, **func_kwargs)
        
        writer.write_frame(processed_frame)
        frames_processed += 1
        
        if show_progress and worker_id == 0 and frames_processed % 10 == 0:
            print(f"\\rProcessing (Worker 0): {(frames_processed / frames_to_process) * 100:.1f}%", end="")

    writer.close()
    cap.release()
    return temp_output


def process_video_parallel(
    input_path: str,
    output_path: str,
    process_func: Callable,
    func_kwargs: Dict[str, Any] = None,
    workers: int = None,
    show_progress: bool = False
) -> Dict[str, Any]:
    """
    A global engine that splits a video, processes chunks in parallel 
    using `process_func`, and stitches them back together.
    
    Args:
        input_path: Path to input video
        output_path: Path to output video
        process_func: Function that takes (frame: np.ndarray, **func_kwargs) and returns a processed frame
        func_kwargs: Additional arguments to pass to process_func
        workers: Number of threads (defaults to os.cpu_count())
        show_progress: Show progress in terminal
    """
    if workers is None:
        workers = os.cpu_count() or 4
    if func_kwargs is None:
        func_kwargs = {}

    result = {"success": False, "output_path": None, "error": None}
    
    try:
        cap = cv2.VideoCapture(input_path)
        if not cap.isOpened():
            result["error"] = f"Could not open video: {input_path}"
            return result

        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        cap.release()
        
        if workers <= 1:
            # Fallback to single-threaded if requested
            workers = 1

        frames_per_thread = math.ceil(total_frames / workers)
        temp_dir = tempfile.mkdtemp()
        
        output_ext = Path(output_path).suffix.lower()
        if not output_ext:
            output_ext = ".mov"
            
        tasks = []
        for i in range(workers):
            start_frame = i * frames_per_thread
            end_frame = min(start_frame + frames_per_thread, total_frames)
            if start_frame >= total_frames:
                break
            tasks.append((
                i, input_path, start_frame, end_frame, 
                temp_dir, fps, width, height, output_ext,
                process_func, func_kwargs, show_progress
            ))
        
        if show_progress:
            print(f"Starting {len(tasks)} workers globally...")
        
        with mp.Pool(workers) as pool:
            temp_files = pool.map(_worker_wrapper, tasks)
            
        # Stitch
        concat_file = os.path.join(temp_dir, "concat.txt")
        with open(concat_file, "w") as f:
            for temp_file in temp_files:
                f.write(f"file '{temp_file}'\\n")
                
        cmd = [
            "ffmpeg", "-y", "-v", "warning", "-f", "concat", "-safe", "0", "-i", concat_file,
            "-c", "copy", output_path
        ]
        subprocess.run(cmd, check=True)
        
        if show_progress:
            print(f"\\rProcessing: 100%                 ")
            
        result["success"] = True
        result["output_path"] = output_path
        return result
        
    except Exception as e:
        result["error"] = str(e)
        return result
