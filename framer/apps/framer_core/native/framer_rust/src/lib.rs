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

#[rustler::nif]
pub fn remove_bg(
    input: String,
    output: String,
    color: String,
    tolerance: u32,
    edges: u32,
    method: String,
) -> NifResult<(Atom, String)> {
    match ops::remove_bg::remove_bg(&input, &output, &color, tolerance, edges, &method) {
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
) -> NifResult<(Atom, String)> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err(Error::Atom("file_not_found"));
    }

    match ops::common::run_ffmpeg(&[
        "-y",
        "-i",
        &input_path,
        "-ss",
        &format!("{}", start_frame as f64 / 30.0),
        "-frames:v",
        &format!("{}", end_frame - start_frame + 1),
        "-c:v",
        "libx264",
        "-preset",
        "fast",
        "-crf",
        "23",
        &output_path,
    ]) {
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
