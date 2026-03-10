import cv2
import sys
import numpy as np

def check(file):
    cap = cv2.VideoCapture(file)
    ret, frame = cap.read()
    if not ret:
        print(f"Could not read {file}")
        return
    
    h, w, c = frame.shape
    print(f"{file} shape: {frame.shape}")
    if c == 4:
        # Check if alpha is just all 255
        unique_a = np.unique(frame[:,:,3])
        print(f"Unique alpha values: {unique_a}")
    else:
        print("NO ALPHA CHANNEL")

check("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg.webm")
check("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg-recolor.webm")
check("/tmp/temp-recolor.webm")
