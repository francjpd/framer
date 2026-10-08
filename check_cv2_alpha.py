import cv2


def check_alpha():
    cap = cv2.VideoCapture("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg.webm")
    # Try disabling RGB conversion
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    ret, frame = cap.read()
    print("CV2 shape with CONVERT_RGB=0:", frame.shape if ret else "Failed")
    cap.release()

if __name__ == "__main__":
    check_alpha()
