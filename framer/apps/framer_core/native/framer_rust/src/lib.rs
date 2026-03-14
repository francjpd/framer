mod ops;

use rustler::{Atom, Error, NifResult};
use std::path::Path;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

// --- NIF wrappers for ops module functions ---

#[rustler::nif]
pub fn get_video_info(path: String) -> NifResult<(Atom, String)> {
    match ops::video_info::get_video_info(&path) {
        Ok(result) => Ok((atoms::ok(), result)),
        Err(e) => Err(e),
    }
}

#[rustler::nif]
pub fn boost_fps(input: String, output: String, target_fps: u32) -> NifResult<(Atom, String)> {
    match ops::fps_boost::boost_fps(&input, &output, target_fps) {
        Ok(result) => Ok((atoms::ok(), result)),
        Err(e) => Err(e),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn remove_bg(
    input: String,
    output: String,
    color: String,
    tolerance: u32,
    edges: u32,
    method: String,
    auto_ranges: bool,
    num_ranges: u32,
    edge_cleanup: u32,
    refine: bool,
    refine_tolerance: u32,
    refine_block_size: u32,
) -> NifResult<(Atom, String)> {
    match ops::remove_bg::remove_bg(
        &input,
        &output,
        &color,
        tolerance,
        edges,
        &method,
        auto_ranges,
        num_ranges,
        edge_cleanup,
        refine,
        refine_tolerance,
        refine_block_size,
    ) {
        Ok(result) => Ok((atoms::ok(), result)),
        Err(e) => Err(e),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn create_loop(
    input: String,
    output: String,
    method: String,
    fade_color: Option<String>,
    fade_frames: Option<u32>,
    morph_steps: Option<u32>,
    hold_frames: Option<u32>,
    blend_mode: Option<String>,
    ramp_factor: Option<f64>,
) -> NifResult<(Atom, String)> {
    match ops::loop_ops::create_loop(
        &input,
        &output,
        &method,
        fade_color.as_deref(),
        fade_frames,
        morph_steps,
        hold_frames,
        blend_mode.as_deref(),
        ramp_factor,
    ) {
        Ok(result) => Ok((atoms::ok(), result)),
        Err(e) => Err(e),
    }
}

// --- Existing NIFs (kept inline) ---

#[rustler::nif]
pub fn process_chunk(
    input_path: String,
    output_path: String,
    start_frame: u64,
    end_frame: u64,
    fps: f64,
    hwaccel: Option<String>,
) -> NifResult<(Atom, String)> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err(Error::Atom("file_not_found"));
    }

    let mut args = vec![
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "error".into(),
        "-y".into(),
    ];

    // Add hardware acceleration if specified
    if let Some(accel) = hwaccel {
        args.extend(ops::common::get_hwaccel_args(&accel));
    }

    args.extend(vec![
        "-i".into(),
        input_path.clone(),
        "-ss".into(),
        format!("{}", start_frame as f64 / fps),
        "-frames:v".into(),
        format!("{}", end_frame - start_frame + 1),
        "-c:v".into(),
        "libx264".into(),
        "-preset".into(),
        "fast".into(),
        "-crf".into(),
        "23".into(),
        output_path.clone(),
    ]);

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

    match ops::common::run_ffmpeg(&args_ref) {
        Ok(_) => Ok((atoms::ok(), output_path)),
        Err(e) => Err(e),
    }
}

#[rustler::nif]
pub fn transcode(
    input_path: String,
    output_path: String,
    codec: String,
    bitrate: String,
) -> NifResult<(Atom, String)> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err(Error::Atom("file_not_found"));
    }

    match ops::common::run_ffmpeg(&[
        "-y",
        "-i",
        &input_path,
        "-c:v",
        &codec,
        "-b:v",
        &bitrate,
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        &output_path,
    ]) {
        Ok(_) => Ok((atoms::ok(), output_path)),
        Err(e) => Err(e),
    }
}

#[rustler::nif]
pub fn apply_filter(
    input_path: String,
    output_path: String,
    filter: String,
) -> NifResult<(Atom, String)> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err(Error::Atom("file_not_found"));
    }

    match ops::common::run_ffmpeg(&[
        "-y",
        "-i",
        &input_path,
        "-vf",
        &filter,
        "-c:a",
        "copy",
        &output_path,
    ]) {
        Ok(_) => Ok((atoms::ok(), output_path)),
        Err(e) => Err(e),
    }
}

rustler::init!("Elixir.FramerCore.Rust");
