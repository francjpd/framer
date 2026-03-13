use super::common::{parse_fps_str, run_ffprobe, validate_path};
use rustler::Error;
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Deserialize)]
struct FfprobeOutput {
    streams: Vec<FfprobeStream>,
}

#[derive(Deserialize)]
struct FfprobeStream {
    codec_type: String,
    width: Option<u32>,
    height: Option<u32>,
    r_frame_rate: Option<String>,
    nb_frames: Option<String>,
}

pub fn get_video_info(path: &str) -> Result<String, Error> {
    let resolved_path: PathBuf = validate_path(path)?;

    let json_str = run_ffprobe(&[
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        resolved_path.to_str().unwrap_or(path),
    ])?;

    let probe: FfprobeOutput =
        serde_json::from_str(&json_str).map_err(|_| Error::Atom("parse_error"))?;

    let video_stream = probe.streams.iter().find(|s| s.codec_type == "video");

    let (width, height, fps, total_frames) = if let Some(stream) = video_stream {
        let fps_str = stream.r_frame_rate.as_deref().unwrap_or("0/1");
        let fps = parse_fps_str(fps_str)?;
        let frames: u64 = stream
            .nb_frames
            .as_deref()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        (
            stream.width.unwrap_or(0),
            stream.height.unwrap_or(0),
            fps,
            frames,
        )
    } else {
        (0, 0, 0.0, 0)
    };

    let result = serde_json::json!({
        "path": path,
        "width": width,
        "height": height,
        "fps": fps,
        "total_frames": total_frames
    });

    Ok(result.to_string())
}
