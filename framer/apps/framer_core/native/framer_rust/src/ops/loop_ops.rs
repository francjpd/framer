use super::common::{
    ensure_output_dir, get_codec_args, get_duration, get_extension, get_fps, run_ffmpeg,
    validate_path,
};
use rustler::Error;
use std::path::PathBuf;

pub fn create_loop(
    input: &str,
    output: &str,
    method: &str,
    fade_color: Option<&str>,
    fade_frames: Option<u32>,
    _morph_steps: Option<u32>,
    hold_frames: Option<u32>,
    blend_mode: Option<&str>,
    ramp_factor: Option<f64>,
) -> Result<String, Error> {
    let _resolved_input: PathBuf = validate_path(input)?;

    // Ensure output directory exists
    let output_path = ensure_output_dir(output)?;

    let ext = get_extension(output);
    let fps = get_fps(input).unwrap_or(30.0);
    let duration = get_duration(input).unwrap_or(1.0);

    match method {
        "pingpong" => create_pingpong(input, &output_path, &ext),
        "reverse" => create_reverse(input, &output_path, &ext),
        "hold" => create_hold(input, &output_path, &ext, hold_frames.unwrap_or(2)),
        "fade" => create_fade(
            input,
            &output_path,
            &ext,
            fade_color.unwrap_or("black"),
            fade_frames.unwrap_or(10),
            fps,
            duration,
        ),
        "blend" => create_blend(input, &output_path, &ext, blend_mode.unwrap_or("addition")),
        "speedramp" => create_speedramp(input, &output_path, &ext, ramp_factor.unwrap_or(1.0)),
        "periodic" => create_periodic(input, &output_path, &ext, duration),
        "morph" => {
            // Morph is complex (needs optical flow). Fallback to pingpong.
            create_pingpong(input, &output_path, &ext)
        }
        _ => {
            // Default: use pingpong
            create_pingpong(input, &output_path, &ext)
        }
    }
}

/// Pingpong: forward then backward (boomerang effect).
fn create_pingpong(input: &str, output: &str, ext: &str) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let filter =
        "[0:v]split[fwd][rev];[rev]reverse[reversed];[fwd][reversed]concat=n=2:v=1:a=0[out]";

    let mut args: Vec<String> = vec![
        "-y".into(),
        "-i".into(),
        input.into(),
        "-filter_complex".into(),
        filter.into(),
        "-map".into(),
        "[out]".into(),
    ];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "pingpong",
        "error": null
    });
    Ok(result.to_string())
}

/// Reverse: full reverse of video, concatenated with original.
fn create_reverse(input: &str, output: &str, ext: &str) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let filter =
        "[0:v]split[fwd][rev];[rev]reverse[reversed];[fwd][reversed]concat=n=2:v=1:a=0[out]";

    let mut args: Vec<String> = vec![
        "-y".into(),
        "-i".into(),
        input.into(),
        "-filter_complex".into(),
        filter.into(),
        "-map".into(),
        "[out]".into(),
    ];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "reverse",
        "error": null
    });
    Ok(result.to_string())
}

/// Hold: freeze last frame using tpad.
fn create_hold(input: &str, output: &str, ext: &str, hold_frames: u32) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let filter = format!("tpad=stop_mode=clone:stop={}", hold_frames);

    let mut args: Vec<String> = vec!["-y".into(), "-i".into(), input.into(), "-vf".into(), filter];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "hold",
        "error": null
    });
    Ok(result.to_string())
}

/// Fade: fade out at end and fade in at start.
fn create_fade(
    input: &str,
    output: &str,
    ext: &str,
    fade_color: &str,
    fade_frames: u32,
    fps: f64,
    duration: f64,
) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let total_frames = (duration * fps) as u32;
    let fade_out_start = if total_frames > fade_frames {
        total_frames - fade_frames
    } else {
        0
    };

    let color = if fade_color == "transparent" || fade_color == "black" {
        "black"
    } else {
        fade_color
    };

    let filter = format!(
        "fade=t=in:st=0:d={}:color={},fade=t=out:st={}:d={}:color={}",
        fade_frames as f64 / fps,
        color,
        fade_out_start as f64 / fps,
        fade_frames as f64 / fps,
        color,
    );

    let mut args: Vec<String> = vec!["-y".into(), "-i".into(), input.into(), "-vf".into(), filter];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "fade",
        "error": null
    });
    Ok(result.to_string())
}

/// Blend: blend forward and reversed streams.
fn create_blend(input: &str, output: &str, ext: &str, blend_mode: &str) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let ffmpeg_mode = match blend_mode {
        "add" => "addition",
        "multiply" => "multiply",
        "screen" => "screen",
        "overlay" => "overlay",
        _ => "addition",
    };

    let filter = format!(
        "[0:v]split[a][b];\
         [b]reverse[br];\
         [a][br]blend=all_mode={}[out]",
        ffmpeg_mode
    );

    let mut args: Vec<String> = vec![
        "-y".into(),
        "-i".into(),
        input.into(),
        "-filter_complex".into(),
        filter,
        "-map".into(),
        "[out]".into(),
    ];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "blend",
        "error": null
    });
    Ok(result.to_string())
}

/// Speedramp: adjust playback speed using setpts filter.
fn create_speedramp(
    input: &str,
    output: &str,
    ext: &str,
    ramp_factor: f64,
) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let factor = ramp_factor.max(0.5).min(2.0);
    let pts_multiplier = 1.0 / factor;
    let filter = format!("setpts={:.4}*PTS", pts_multiplier);

    let mut args: Vec<String> = vec!["-y".into(), "-i".into(), input.into(), "-vf".into(), filter];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "speedramp",
        "error": null
    });
    Ok(result.to_string())
}

/// Periodic: trim video to estimated cycle length.
fn create_periodic(input: &str, output: &str, ext: &str, duration: f64) -> Result<String, Error> {
    let has_alpha = super::common::detect_alpha(input).unwrap_or(false);
    let codec_args = get_codec_args(ext, has_alpha);

    let cycle_duration = duration / 2.0;

    let mut args: Vec<String> = vec![
        "-y".into(),
        "-i".into(),
        input.into(),
        "-t".into(),
        format!("{:.3}", cycle_duration),
    ];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output.into());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output,
        "method": "periodic",
        "error": null
    });
    Ok(result.to_string())
}
