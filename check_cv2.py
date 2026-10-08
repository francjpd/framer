import cv2


def check_alpha():
    cap = cv2.VideoCapture("../agent-hotel/agent_collab/priv/static/videos/octo-infinity-bg.webm")
    _ret, frame = cap.read()
    print("CV2 shape:", frame.shape)
    cap.release()

if __name__ == "__main__":
    check_alpha()
