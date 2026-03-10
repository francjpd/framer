import cv2
import multiprocessing as mp
import math
import tempfile
import subprocess
import os
import time
import sys

from core.bg_removal import _process_frame, generate_color_ranges, detect_background_color_from_video
from core.video import VideoStreamWriter

def worker(args):
    import time
    worker_id, input_path, start_frame, end_frame, bg_color, tolerance, temp_dir = args
    t0 = time.time()
    print(f"Worker {worker_id} starting: frames {start_frame} to {end_frame}")
    
    cap = cv2.VideoCapture(input_path)
    t1 = time.time()
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    t2 = time.time()
    
    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    color_ranges = generate_color_ranges(bg_color, 5, tolerance)
    
    temp_output = os.path.join(temp_dir, f"part_{worker_id:03d}.mov")
    
    writer = VideoStreamWriter(
        output_path=temp_output,
        fps=fps,
        width=width,
        height=height,
        has_alpha=True,
        loop=False
    )
    t3 = time.time()
    
    frames_to_process = end_frame - start_frame
    frames_processed = 0
    
    for _ in range(frames_to_process):
        ret, frame = cap.read()
        if not ret:
            break
            
        alpha = _process_frame(
            frame,
            color_ranges,
            soft_edges=5,
            edge_cleanup=3,
            use_adaptive_bg=False
        )
        
        b, g, r = cv2.split(frame)
        bgra = cv2.merge([b, g, r, alpha])
        writer.write_frame(bgra)
        frames_processed += 1
        
    t4 = time.time()
    writer.close()
    cap.release()
    t5 = time.time()
    print(f"Worker {worker_id} finished. Read: {t1-t0:.2f}s, Seek: {t2-t1:.2f}s, Writer: {t3-t2:.2f}s, Process: {t4-t3:.2f}s, Close: {t5-t4:.2f}s")
    
    return temp_output

def parallel_remove_bg(input_path, output_path, num_threads=4):
    start_time = time.time()
    
    cap = cv2.VideoCapture(input_path)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    cap.release()
    
    print(f"Video has {total_frames} frames.")
    
    bg_colors = detect_background_color_from_video(input_path, tolerance=30)
    bg_color = bg_colors[0] if bg_colors else [115, 188, 129] # Fallback green
    
    frames_per_thread = math.ceil(total_frames / num_threads)
    
    temp_dir = tempfile.mkdtemp()
    print(f"Using temp dir: {temp_dir}")
    
    tasks = []
    for i in range(num_threads):
        start_frame = i * frames_per_thread
        end_frame = min(start_frame + frames_per_thread, total_frames)
        if start_frame >= total_frames:
            break
        tasks.append((i, input_path, start_frame, end_frame, bg_color, 30, temp_dir))
        
    print(f"Starting {len(tasks)} processes with up to {frames_per_thread} frames each...")
    
    with mp.Pool(num_threads) as pool:
        temp_files = pool.map(worker, tasks)
        
    print("Concatenating parts...")
    
    concat_file = os.path.join(temp_dir, "concat.txt")
    with open(concat_file, "w") as f:
        for temp_file in temp_files:
            # Escape path for FFmpeg if needed, but safe here
            f.write(f"file '{temp_file}'\n")
            
    # run ffmpeg to concat
    cmd = [
        "ffmpeg", "-y", "-v", "warning", "-f", "concat", "-safe", "0", "-i", concat_file,
        "-c", "copy", output_path
    ]
    subprocess.run(cmd, check=True)
    
    end_time = time.time()
    print(f"Done! Output saved to {output_path}")
    print(f"Total time taken: {end_time - start_time:.2f} seconds")

def single_thread_remove_bg(input_path, output_path):
    print("--- Running single-threaded for comparison ---")
    start_time = time.time()
    from core.bg_removal import remove_background
    remove_background(input_path, output_path, show_progress=False)
    end_time = time.time()
    print(f"Single-threaded time taken: {end_time - start_time:.2f} seconds")

if __name__ == '__main__':
    if not os.path.exists("octopus-green.mp4"):
        print("octopus-green.mp4 not found. Please provide a valid video.")
        sys.exit(1)
        
    threads = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    
    # Run parallel version
    parallel_remove_bg("octopus-green.mp4", "poc_output_parallel.mov", num_threads=threads)
    
    # Run single-threaded version for comparison
    single_thread_remove_bg("octopus-green.mp4", "poc_output_single.mov")
