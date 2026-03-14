use rustler::Error;
use std::path::Path;
use std::process::Command;

/// Run an FFmpeg command and return the output path on success.
pub fn run_ffmpeg(args: &[&str]) -> Result<String, Error> {
    use std::io::Read;
    use std::process::Stdio;

    let mut cmd = Command::new("ffmpeg");
    cmd.args(args).stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to spawn ffmpeg: {}", e);
            return Err(Error::Atom("ffmpeg_not_found"));
        }
    };

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();

    let mut out = match child.stdout.take() {
        Some(o) => o,
        None => return Err(Error::Atom("ffmpeg_io_error")),
    };
    let mut err = match child.stderr.take() {
        Some(e) => e,
        None => return Err(Error::Atom("ffmpeg_io_error")),
    };

    // Read all output
    let _ = out.read_to_end(&mut stdout);
    let _ = err.read_to_end(&mut stderr);

    // Wait with retries for BEAM reaping
    let mut retries = 0;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) => {
                retries += 1;
                if retries > 50 {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                if retries > 100 {
                    let _ = child.kill();
                    return Err(Error::Atom("ffmpeg_timeout"));
                }
            }
            // Process was reaped by BEAM - check if we got output or if it's a silent success
            Err(_) => {
                let stderr_str = String::from_utf8_lossy(&stderr);
                if stderr_str.contains("error")
                    || stderr_str.contains("Error")
                    || stderr_str.contains("failed")
                {
                    eprintln!("{}", stderr_str.trim());
                    return Err(Error::Atom("ffmpeg_failed"));
                }
                // If there's no error in stderr, assume it finished successfully (even if silent)
                return Ok(String::from_utf8_lossy(&stdout).to_string());
            }
        }
    };

    if status.success() {
        Ok(String::from_utf8_lossy(&stdout).to_string())
    } else {
        let stderr_str = String::from_utf8_lossy(&stderr).to_string();
        let stderr_trimmed = stderr_str.trim().to_string();

        eprintln!("{}", stderr_trimmed);
        Err(Error::Atom("ffmpeg_failed"))
    }
}

/// Run ffprobe and return stdout as a string.
pub fn run_ffprobe(args: &[&str]) -> Result<String, Error> {
    use std::io::Read;
    use std::process::Stdio;

    let mut child = Command::new("/usr/bin/ffprobe")
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| Error::Atom("ffprobe_not_found"))?;

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();

    if let Some(mut out) = child.stdout.take() {
        let _ = out.read_to_end(&mut stdout);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = err.read_to_end(&mut stderr);
    }

    let out_str = String::from_utf8_lossy(&stdout).trim().to_string();
    if out_str.is_empty() {
        let err_str = String::from_utf8_lossy(&stderr);
        eprintln!("ffprobe error: {}", err_str);
        Err(Error::Atom("ffprobe_error"))
    } else {
        Ok(out_str)
    }
}

/// Validate that a file exists. Resolves relative paths against current dir.
pub fn validate_path(path: &str) -> Result<std::path::PathBuf, Error> {
    let path_buf = Path::new(path);
    if path_buf.is_absolute() {
        if path_buf.exists() {
            Ok(path_buf.to_path_buf())
        } else {
            Err(Error::Atom("file_not_found"))
        }
    } else {
        // Resolve relative path against current working directory
        let cwd = std::env::current_dir().map_err(|_| Error::Atom("invalid_path"))?;
        let resolved = cwd.join(path_buf);
        if resolved.exists() {
            Ok(resolved)
        } else {
            Err(Error::Atom("file_not_found"))
        }
    }
}

/// Get the FPS of a video file.
/// Get FFmpeg arguments for hardware acceleration.
pub fn get_hwaccel_args(accel_type: &str) -> Vec<String> {
    match accel_type {
        "auto" => vec!["-hwaccel".into(), "auto".into()],
        "cuda" => vec![
            "-hwaccel".into(),
            "cuda".into(),
            "-hwaccel_output_format".into(),
            "cuda".into(),
        ],
        "vaapi" => vec!["-hwaccel".into(), "vaapi".into()],
        _ => vec![],
    }
}

pub fn get_fps(path: &str) -> Result<f64, Error> {
    let fps_str = run_ffprobe(&[
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=avg_frame_rate",
        "-of",
        "csv=p=0",
        path,
    ])?;

    parse_fps_str(&fps_str)
}

/// Parse an FPS string like "30/1" or "29.97" into f64.
pub fn parse_fps_str(fps_str: &str) -> Result<f64, Error> {
    let trimmed = fps_str.trim();
    if trimmed.contains('/') {
        let parts: Vec<&str> = trimmed.split('/').collect();
        if parts.len() == 2 {
            let num: f64 = parts[0].parse().unwrap_or(0.0);
            let den: f64 = parts[1].parse().unwrap_or(1.0);
            if den > 0.0 {
                Ok(num / den)
            } else {
                Ok(0.0)
            }
        } else {
            Ok(0.0)
        }
    } else {
        Ok(trimmed.parse().unwrap_or(0.0))
    }
}

/// Detect if a video has an alpha channel.
pub fn detect_alpha(path: &str) -> Result<bool, Error> {
    // Check alpha_mode tag (VP9 with alpha)
    let alpha_mode = run_ffprobe(&[
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream_tags=alpha_mode",
        "-of",
        "csv=p=0",
        path,
    ])
    .unwrap_or_default();

    if alpha_mode.contains('1') {
        return Ok(true);
    }

    // Check pixel format
    let pix_fmt = run_ffprobe(&[
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=pix_fmt",
        "-of",
        "csv=p=0",
        path,
    ])
    .unwrap_or_default();

    Ok(pix_fmt.contains("yuva")
        || pix_fmt.contains("bgra")
        || pix_fmt.contains("argb")
        || pix_fmt.contains("gba"))
}

/// Get the duration of a video in seconds.
pub fn get_duration(path: &str) -> Result<f64, Error> {
    let dur_str = run_ffprobe(&[
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        path,
    ])?;

    dur_str
        .trim()
        .parse::<f64>()
        .map_err(|_| Error::Atom("parse_error"))
}

/// Get the total frame count of a video.
pub fn get_frame_count(path: &str) -> Result<u64, Error> {
    let count_str = run_ffprobe(&[
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-count_frames",
        "-show_entries",
        "stream=nb_read_frames",
        "-of",
        "csv=p=0",
        path,
    ])?;

    count_str
        .trim()
        .parse::<u64>()
        .map_err(|_| Error::Atom("parse_error"))
}

/// Check if minterpolate filter is available.
pub fn has_minterpolate() -> bool {
    Command::new("/usr/bin/ffmpeg")
        .args(&["-filters"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("minterpolate"))
        .unwrap_or(false)
}

/// Get codec arguments based on output extension and alpha status.
pub fn get_codec_args(ext: &str, has_alpha: bool) -> Vec<String> {
    match ext {
        ".webm" => vec![
            "-c:v".into(),
            "libvpx-vp9".into(),
            "-pix_fmt".into(),
            "yuva420p".into(),
            "-auto-alt-ref".into(),
            "0".into(),
            "-crf".into(),
            "30".into(),
            "-b:v".into(),
            "0".into(),
        ],
        ".mov" => {
            if has_alpha {
                vec![
                    "-c:v".into(),
                    "qtrle".into(),
                    "-pix_fmt".into(),
                    "argb".into(),
                ]
            } else {
                vec!["-c:v".into(), "qtrle".into()]
            }
        }
        _ => vec![
            "-c:v".into(),
            "libx264".into(),
            "-preset".into(),
            "medium".into(),
            "-crf".into(),
            "23".into(),
        ],
    }
}

/// Parse a color string in BGR ("B,G,R" like "0,255,0") or RGB hex ("#00FF00") format
/// and return a hex color string in the format FFmpeg expects for colorkey/chromakey.
///
/// FFmpeg colorkey filter expects colors in **RGB** hex: "#RRGGBB".
/// The CLI convention (matching OpenCV/Python) is that comma-separated values are B,G,R.
/// So "0,255,0" = B=0, G=255, R=0 (pure green in BGR). For FFmpeg we need #00FF00.
///
/// The conversion: output "#{R:02X}{G:02X}{B:02X}" — i.e. swap parts[0](B) with parts[2](R).
pub fn parse_color_to_hex(color: &str) -> Result<String, Error> {
    let trimmed = color.trim();

    if trimmed.starts_with('#') {
        // "#RRGGBB" — already RGB, return as is (FFmpeg likes #)
        Ok(trimmed.to_string())
    } else if trimmed.contains(',') {
        // "B,G,R" comma-separated (CLI convention matches OpenCV BGR)
        // Must convert to "#RRGGBB" for FFmpeg (swap B and R).
        let parts: Vec<&str> = trimmed.split(',').collect();
        if parts.len() == 3 {
            let b: u8 = parts[0]
                .trim()
                .parse()
                .map_err(|_| Error::Atom("invalid_color"))?;
            let g: u8 = parts[1]
                .trim()
                .parse()
                .map_err(|_| Error::Atom("invalid_color"))?;
            let r: u8 = parts[2]
                .trim()
                .parse()
                .map_err(|_| Error::Atom("invalid_color"))?;

            // Output as #RRGGBB for FFmpeg
            Ok(format!("#{:02X}{:02X}{:02X}", r, g, b))
        } else {
            Err(Error::Atom("invalid_color"))
        }
    } else if trimmed.starts_with("0x") || trimmed.starts_with("0X") {
        // "0xRRGGBB" — already RGB hex, pass straight through
        let hex = &trimmed[2..];
        if hex.len() == 6 {
            u8::from_str_radix(&hex[0..2], 16).map_err(|_| Error::Atom("invalid_color"))?;
            u8::from_str_radix(&hex[2..4], 16).map_err(|_| Error::Atom("invalid_color"))?;
            u8::from_str_radix(&hex[4..6], 16).map_err(|_| Error::Atom("invalid_color"))?;
            Ok(format!("0x{}", hex.to_uppercase()))
        } else {
            Err(Error::Atom("invalid_color"))
        }
    } else {
        Err(Error::Atom("invalid_color"))
    }
}

/// Get the file extension from a path, lowercase with leading dot.
pub fn get_extension(path: &str) -> String {
    Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_lowercase()))
        .unwrap_or_else(|| ".mp4".to_string())
}

/// Ensure the output directory exists, creating it if necessary.
pub fn ensure_output_dir(output_path: &str) -> Result<String, Error> {
    let path = Path::new(output_path);

    // Get the directory part of the path
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            // Try to create the directory (and any missing parents)
            if !parent.exists() {
                std::fs::create_dir_all(parent)
                    .map_err(|_| Error::Atom("output_dir_create_failed"))?;
            }
        }
    }

    // Return the resolved absolute path
    if path.is_absolute() {
        Ok(output_path.to_string())
    } else {
        let cwd = std::env::current_dir().map_err(|_| Error::Atom("invalid_path"))?;
        Ok(cwd.join(path).to_string_lossy().to_string())
    }
}
