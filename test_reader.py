import subprocess
import time

import numpy as np


def read_frames_ffmpeg(input_path, start_frame, num_frames, fps, width, height, has_alpha=True):
    start_time_sec = start_frame / fps
    channels = 4 if has_alpha else 3
    pix_fmt = "bgra" if has_alpha else "bgr24"
    frame_size = width * height * channels

    cmd = [
        "ffmpeg",
        "-ss", str(start_time_sec),
        "-i", input_path,
        "-vframes", str(num_frames),
        "-f", "image2pipe",
        "-pix_fmt", pix_fmt,
        "-vcodec", "rawvideo",
        "-loglevel", "error",
        "-"
    ]

    t0 = time.time()
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    frames_read = 0
    while frames_read < num_frames:
        raw_frame = process.stdout.read(frame_size)
        if not raw_frame or len(raw_frame) != frame_size:
            break
            
        frame = np.frombuffer(raw_frame, dtype=np.uint8).reshape((height, width, channels))
        frames_read += 1
        
    process.stdout.close()
    process.wait()
    t1 = time.time()
    
    print(f"Read {frames_read} frames. Alpha sum of last frame: {frame[:, :, 3].sum() if has_alpha and frames_read > 0 else 0}")
    print(f"Time: {t1-t0:.2f}s")
    return frames_read

if __name__ == "__main__":
    read_frames_ffmpeg("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg.webm", 0, 10, 30.0, 1920, 1080, True)
    read_frames_ffmpeg("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg.webm", 50, 10, 30.0, 1920, 1080, True)
