import sys

def patch_bg_removal():
    with open("core/bg_removal.py", "r") as f:
        content = f.read()

    # Part 1: Add _worker_process_chunk and add workers arg to remove_background
    old_sig = '''def remove_background(
    input_path: str,
    output_path: str,
    background_color: list = None,
    tolerance: int = 30,
    soft_edges: int = 5,
    show_progress: bool = False,
    auto_ranges: bool = True,
    num_ranges: int = 5,
    method: str = "color",
    motion_frames: int = 30,
    motion_threshold: int = 15,
    edge_cleanup: int = 3,
    adaptive_bg: bool = False,
    refine: bool = False,
    refine_tolerance: int = 45,
    refine_block_size: int = 32,
    refine_interactive: bool = False,
    refine_save_previews: bool = False,
) -> Dict[str, Any]:'''

    new_sig = '''def _worker_process_chunk(args):
    (
        worker_id, input_path, start_frame, end_frame, color_ranges,
        method, motion_mask, background_color, tolerance,
        refine, refine_tolerance, refine_block_size, edge_cleanup,
        soft_edges, adaptive_bg, temp_dir, fps, width, height, show_progress
    ) = args

    import cv2
    import os
    from core.video import VideoStreamWriter
    
    cap = cv2.VideoCapture(input_path)
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    
    temp_output = os.path.join(temp_dir, f"part_{worker_id:04d}.mov")
    
    writer = VideoStreamWriter(
        output_path=temp_output,
        fps=fps,
        width=width,
        height=height,
        has_alpha=True,
        loop=False
    )

    frames_to_process = end_frame - start_frame
    frames_processed = 0

    while frames_processed < frames_to_process:
        ret, frame = cap.read()
        if not ret:
            break

        first_pass_edge_cleanup = None if refine else edge_cleanup
        first_pass_soft_edges = None if refine else soft_edges

        if method == "color":
            alpha = _process_frame(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
        elif method == "motion" and motion_mask is not None:
            alpha = create_motion_based_mask(
                frame, motion_mask, background_color, tolerance
            )
        elif method == "combined" and motion_mask is not None:
            color_alpha = _process_frame(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )
            motion_alpha = create_motion_based_mask(
                frame, motion_mask, background_color, tolerance
            )
            alpha = cv2.bitwise_or(color_alpha, motion_alpha)
        else:
            alpha = _process_frame(
                frame,
                color_ranges,
                first_pass_soft_edges,
                first_pass_edge_cleanup,
                adaptive_bg,
            )

        if refine:
            alpha = refine_frame(
                bgr_frame=frame,
                alpha=alpha,
                background_color=background_color,
                tolerance=refine_tolerance,
                block_size=refine_block_size,
                edge_cleanup=edge_cleanup,
                soft_edges=soft_edges
            )

        b, g, r = cv2.split(frame)
        bgra = cv2.merge([b, g, r, alpha])
        
        writer.write_frame(bgra)
        frames_processed += 1
        
        if show_progress and worker_id == 0 and frames_processed % 10 == 0:
            print(f"\\rProcessing (Worker 0): {(frames_processed / frames_to_process) * 100:.1f}%", end="")

    writer.close()
    cap.release()
    return temp_output

def remove_background(
    input_path: str,
    output_path: str,
    background_color: list = None,
    tolerance: int = 30,
    soft_edges: int = 5,
    show_progress: bool = False,
    auto_ranges: bool = True,
    num_ranges: int = 5,
    method: str = "color",
    motion_frames: int = 30,
    motion_threshold: int = 15,
    edge_cleanup: int = 3,
    adaptive_bg: bool = False,
    refine: bool = False,
    refine_tolerance: int = 45,
    refine_block_size: int = 32,
    refine_interactive: bool = False,
    refine_save_previews: bool = False,
    workers: int = 1,
) -> Dict[str, Any]:'''
    
    if old_sig not in content:
        print("Could not find old_sig in core/bg_removal.py")
        sys.exit(1)
        
    content = content.replace(old_sig, new_sig)
    
    # Part 2: Multiprocessing logic
    old_loop = '''        from core.video import VideoStreamWriter
        
        with VideoStreamWriter(
            output_path=output_path,
            fps=fps,
            width=width,
            height=height,
            has_alpha=True
        ) as writer:
            frame_count = 0
            while True:
                ret, frame = cap.read()
                if not ret:
                    break

                first_pass_edge_cleanup = None if refine else edge_cleanup
                first_pass_soft_edges = None if refine else soft_edges

                if method == "color":
                    alpha = _process_frame(
                        frame,
                        color_ranges,
                        first_pass_soft_edges,
                        first_pass_edge_cleanup,
                        adaptive_bg,
                    )
                elif method == "motion" and motion_mask is not None:
                    alpha = create_motion_based_mask(
                        frame, motion_mask, background_color, tolerance
                    )
                elif method == "combined" and motion_mask is not None:
                    color_alpha = _process_frame(
                        frame,
                        color_ranges,
                        first_pass_soft_edges,
                        first_pass_edge_cleanup,
                        adaptive_bg,
                    )
                    motion_alpha = create_motion_based_mask(
                        frame, motion_mask, background_color, tolerance
                    )
                    alpha = cv2.bitwise_or(color_alpha, motion_alpha)
                else:
                    alpha = _process_frame(
                        frame,
                        color_ranges,
                        first_pass_soft_edges,
                        first_pass_edge_cleanup,
                        adaptive_bg,
                    )

                if refine:
                    alpha = refine_frame(
                        bgr_frame=frame,
                        alpha=alpha,
                        background_color=background_color,
                        tolerance=refine_tolerance,
                        block_size=refine_block_size,
                        edge_cleanup=edge_cleanup,
                        soft_edges=soft_edges
                    )

                b, g, r = cv2.split(frame)
                bgra = cv2.merge([b, g, r, alpha])
                
                writer.write_frame(bgra)

                frame_count += 1
                if show_progress and frame_count % 10 == 0:
                    print(
                        f"\\rProcessing: {(frame_count / total_frames) * 100:.1f}%", end=""
                    )

        cap.release()
        if show_progress:
            print(f"\\rProcessing: 100%")

        result["success"] = True
        result["output_path"] = output_path
        return result'''

    new_loop = '''        if workers > 1:
            import multiprocessing as mp
            import math
            import os
            
            cap.release()
            
            frames_per_thread = math.ceil(total_frames / workers)
            temp_dir = tempfile.mkdtemp()
            
            tasks = []
            for i in range(workers):
                start_frame = i * frames_per_thread
                end_frame = min(start_frame + frames_per_thread, total_frames)
                if start_frame >= total_frames:
                    break
                tasks.append((
                    i, input_path, start_frame, end_frame, color_ranges,
                    method, motion_mask, background_color, tolerance,
                    refine, refine_tolerance, refine_block_size, edge_cleanup,
                    soft_edges, adaptive_bg, temp_dir, fps, width, height, show_progress
                ))
            
            if show_progress:
                print(f"Starting {len(tasks)} workers...")
            
            with mp.Pool(workers) as pool:
                temp_files = pool.map(_worker_process_chunk, tasks)
                
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
            
        else:
            from core.video import VideoStreamWriter
            
            with VideoStreamWriter(
                output_path=output_path,
                fps=fps,
                width=width,
                height=height,
                has_alpha=True
            ) as writer:
                frame_count = 0
                while True:
                    ret, frame = cap.read()
                    if not ret:
                        break
    
                    first_pass_edge_cleanup = None if refine else edge_cleanup
                    first_pass_soft_edges = None if refine else soft_edges
    
                    if method == "color":
                        alpha = _process_frame(
                            frame,
                            color_ranges,
                            first_pass_soft_edges,
                            first_pass_edge_cleanup,
                            adaptive_bg,
                        )
                    elif method == "motion" and motion_mask is not None:
                        alpha = create_motion_based_mask(
                            frame, motion_mask, background_color, tolerance
                        )
                    elif method == "combined" and motion_mask is not None:
                        color_alpha = _process_frame(
                            frame,
                            color_ranges,
                            first_pass_soft_edges,
                            first_pass_edge_cleanup,
                            adaptive_bg,
                        )
                        motion_alpha = create_motion_based_mask(
                            frame, motion_mask, background_color, tolerance
                        )
                        alpha = cv2.bitwise_or(color_alpha, motion_alpha)
                    else:
                        alpha = _process_frame(
                            frame,
                            color_ranges,
                            first_pass_soft_edges,
                            first_pass_edge_cleanup,
                            adaptive_bg,
                        )
    
                    if refine:
                        alpha = refine_frame(
                            bgr_frame=frame,
                            alpha=alpha,
                            background_color=background_color,
                            tolerance=refine_tolerance,
                            block_size=refine_block_size,
                            edge_cleanup=edge_cleanup,
                            soft_edges=soft_edges
                        )
    
                    b, g, r = cv2.split(frame)
                    bgra = cv2.merge([b, g, r, alpha])
                    
                    writer.write_frame(bgra)
    
                    frame_count += 1
                    if show_progress and frame_count % 10 == 0:
                        print(
                            f"\\rProcessing: {(frame_count / total_frames) * 100:.1f}%", end=""
                        )
    
            cap.release()
            if show_progress:
                print(f"\\rProcessing: 100%")
    
            result["success"] = True
            result["output_path"] = output_path
            return result'''
            
    if old_loop not in content:
        print("Could not find old_loop in core/bg_removal.py")
        sys.exit(1)
        
    content = content.replace(old_loop, new_loop)
    
    with open("core/bg_removal.py", "w") as f:
        f.write(content)

def patch_ops_remove_bg():
    with open("ops/remove_bg.py", "r") as f:
        content = f.read()
        
    # Signature
    old_sig = '''    refine_block_size: int = 32,
    progress: bool = False,
    refine_save_previews: bool = False,
    config: str | None = None,
) -> Dict[str, Any]:'''
    new_sig = '''    refine_block_size: int = 32,
    progress: bool = False,
    refine_save_previews: bool = False,
    workers: int = 1,
    config: str | None = None,
) -> Dict[str, Any]:'''
    content = content.replace(old_sig, new_sig)
    
    # Config
    old_cfg = '''        refine_tolerance = bg_options.get("refine_tolerance", refine_tolerance)
        refine_block_size = bg_options.get("refine_block_size", refine_block_size)

    # Parse color'''
    new_cfg = '''        refine_tolerance = bg_options.get("refine_tolerance", refine_tolerance)
        refine_block_size = bg_options.get("refine_block_size", refine_block_size)
        workers = bg_options.get("workers", workers)

    # Parse color'''
    content = content.replace(old_cfg, new_cfg)
    
    # Call
    old_call = '''        adaptive_bg=adaptive_bg,
        refine=refine,
        refine_tolerance=refine_tolerance,
        refine_block_size=refine_block_size,
    )'''
    new_call = '''        adaptive_bg=adaptive_bg,
        refine=refine,
        refine_tolerance=refine_tolerance,
        refine_block_size=refine_block_size,
        workers=workers,
    )'''
    content = content.replace(old_call, new_call)
    
    # Args schema
    old_schema = '''        "config": {
            "type": "string",
            "default": None,
            "description": "Path to config JSON file (exclusive)",
        },
    },
    description="Remove background from video with alpha channel",'''
    new_schema = '''        "workers": {
            "type": "int",
            "default": 1,
            "short": "-w",
            "description": "Number of worker threads (default: 1)",
        },
        "config": {
            "type": "string",
            "default": None,
            "description": "Path to config JSON file (exclusive)",
        },
    },
    description="Remove background from video with alpha channel",'''
    content = content.replace(old_schema, new_schema)
    
    with open("ops/remove_bg.py", "w") as f:
        f.write(content)

if __name__ == "__main__":
    patch_bg_removal()
    patch_ops_remove_bg()
    print("Patched successfully!")
