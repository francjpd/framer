import sys

import cv2
import numpy as np


def get_dominant_color(video_path):
    cap = cv2.VideoCapture(video_path)
    ret, frame = cap.read()
    cap.release()
    if not ret:
        print("Could not read video")
        sys.exit(1)
        
    # If it has alpha, only look at non-transparent pixels
    if frame.shape[2] == 4:
        mask = frame[:,:,3] > 0
        pixels = frame[mask][:, :3]
    else:
        # Just grab the center of the frame assuming the subject is there
        h, w = frame.shape[:2]
        pixels = frame[h//4:3*h//4, w//4:3*w//4].reshape(-1, 3)

    if len(pixels) == 0:
        pixels = frame.reshape(-1, 3)

    # Convert to float and get average color
    avg_color = np.median(pixels, axis=0)
    b, g, r = avg_color
    
    # Print hex
    print(f"#{int(r):02x}{int(g):02x}{int(b):02x}")

get_dominant_color("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg.webm")
