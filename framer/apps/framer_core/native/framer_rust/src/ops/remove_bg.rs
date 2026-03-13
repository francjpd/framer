use super::common::{
    ensure_output_dir, get_extension, parse_color_to_hex, run_ffmpeg, validate_path,
};
use rustler::Error;
use std::path::PathBuf;

pub fn remove_bg(
    input: &str,
    output: &str,
    color: &str,
    tolerance: u32,
    edges: u32,
    method: &str,
) -> Result<String, Error> {
    let _resolved_input: PathBuf = validate_path(input)?;

    // Ensure output directory exists
    let output_path = ensure_output_dir(output)?;

    let ext = get_extension(output);

    // Validate output format supports alpha
    if ext == ".mp4" {
        let result = serde_json::json!({
            "success": false,
            "output_path": null,
            "error": "MP4 does not support alpha channel. Use .webm or .mov for background removal."
        });
        return Ok(result.to_string());
    }

    // Parse color to FFmpeg hex format
    let hex_color = parse_color_to_hex(color)?;

    // Convert tolerance from 0-255 range to FFmpeg similarity 0.0-1.0
    let similarity = (tolerance as f64) / 255.0;
    let similarity = similarity.min(1.0).max(0.01);

    // Build filter chain based on method
    let filter = match method {
        "chromakey" => {
            let mut f = format!(
                "chromakey=color={}:similarity={:.2}:blend=0.1",
                hex_color, similarity
            );
            if edges > 0 {
                f.push_str(&format!(",gblur=sigma={}", edges));
            }
            f
        }
        _ => {
            let mut f = format!(
                "colorkey=color={}:similarity={:.2}:blend=0.1,format=yuva420p",
                hex_color, similarity
            );
            if edges > 0 {
                f.push_str(&format!(
                    ",split[rgb][alpha];[alpha]alphaextract,gblur=sigma={}[softedge];[rgb][softedge]alphamerge",
                    edges
                ));
            }
            f
        }
    };

    // Build codec args for alpha output
    let codec_args: Vec<String> = match ext.as_str() {
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
        ".mov" => vec![
            "-c:v".into(),
            "qtrle".into(),
            "-pix_fmt".into(),
            "argb".into(),
        ],
        _ => vec![
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
    };

    let mut args: Vec<String> = vec!["-y".into(), "-i".into(), input.into(), "-vf".into(), filter];

    args.extend(codec_args);
    args.push("-an".into());
    args.push(output_path.clone());

    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_ffmpeg(&args_ref)?;

    let result = serde_json::json!({
        "success": true,
        "output_path": output_path,
        "error": null
    });

    Ok(result.to_string())
}
