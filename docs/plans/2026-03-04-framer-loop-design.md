# Video Looper & Framer Rename - Design

> **For Claude:** Implementation follows in separate plan.

## Overview
Rename project from `bg-remover` to `framer` and add video looper feature for creating seamless infinite loops.

---

## Part 1: Project Rename

### Changes Required
- [x] `.gitignore` - add `.worktrees/` (DONE)
- [ ] Rename `bgremover.py` → `framer.py`
- [ ] Rename `bg-remover/` directory → `framer/` (in imports)
- [ ] Update `README.md` title and references
- [ ] Update `pyproject.toml` project name (optional)
- [ ] Git commit with rename

---

## Part 2: Video Looper Feature

### CLI Interface
```bash
python cli.py input.mp4 output.mp4 loop \
  --method auto              # cut, crossfade, stretch, or auto
  --first-frames 20         # frames to scan at start (default: 20)
  --last-frames 20          # frames to match at end (default: 20)
  --match-threshold 85      # pose similarity % (default: 85)
  --show-matches            # preview matched frame pairs
```

### Architecture

1. **Frame Extraction**
   - Extract first N and last M frames from video
   - Store as temporary PNG sequence or numpy arrays

2. **Pose/Motion Detection** (auto-detect)
   - People in video → MediaPipe body keypoints
   - General motion → Optical flow / feature matching
   - Use OpenCV built-in features (no external deps if possible)

3. **Similarity Scoring**
   - For pose: compare keypoint positions between frame pairs
   - For optical flow: compare motion vectors
   - Return similarity percentage (0-100%)

4. **Loop Methods**
   - `cut`: Hard cut at best matching frame pair
   - `crossfade`: Blend last N frames with first N frames  
   - `stretch`: Time-stretch to align poses
   - `auto`: Automatically pick best method based on similarity score

### Output
- Looped video file (MP4/WebM/MOV)
- Seamless playback from end back to start

---

## Tech Stack
- Python 3.14+
- OpenCV (existing)
- NumPy (existing)
- FFmpeg (existing, for encoding)
- MediaPipe (optional, for human pose detection)

---

## Notes
- Keep dependencies minimal
- Support video formats: MP4, WebM, MOV
- Output same format as input or specified
