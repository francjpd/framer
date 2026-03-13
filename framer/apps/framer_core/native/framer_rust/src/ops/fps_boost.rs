use super::common::{
    detect_alpha, ensure_output_dir, get_codec_args, get_extension, get_fps, has_minterpolate,
    run_ffmpeg, validate_path,
};
use rustler::Error;
use std::path::PathBuf;

pub fn boost_fps(input: &str, output: &str, target_fps: u32) -> Result<String, Error> {
    let _resolved_input: PathBuf = validate_path(input)?;

    // Ensure output directory exists
    let output_path = ensure_output_dir(output)?;

    let original_fps = get_fps(input)?;
    let has_alpha = detect_alpha(input)?;
    let ext = get_extension(output);

    // Check alpha + mp4 incompatibility
    if has_alpha && ext == ".mp4" {
        let result = serde_json::json!({
            "success": false,
            "output_path": null,
            "error": "MP4 does not support alpha channel. Use .webm or .mov for output with alpha."
        });
        return Ok(result.to_string());
    }

    let codec_args = get_codec_args(&ext, has_alpha);

    let mut args: Vec<String> = vec!["-y".into(), "-i".into(), input.into()];

    if original_fps >= target_fps as f64 {
        args.push("-r".into());
        args.push(target_fps.to_string());
    } else {
        let filter_str = if has_minterpolate() {
            let mut f = format!(
                "minterpolate=fps={}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1",
                target_fps
            );
            if has_alpha {
                f.push_str(",format=yuva420p");
            }
            f
        } else {
            let mut f = format!("fps={}", target_fps);
            if has_alpha {
                f.push_str(",format=yuva420p");
            }
            f
        };

        args.push("-vf".into());
        args.push(filter_str);
    }

    args.extend(codec_args);
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
