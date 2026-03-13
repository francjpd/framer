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
    _auto_ranges: bool,
    _num_ranges: u32,
    edge_cleanup: u32,
    refine: bool,
    refine_tolerance: u32,
    _refine_block_size: u32,
) -> Result<String, Error> {
    let _resolved_input: PathBuf = validate_path(input)?;

    let output_path = ensure_output_dir(output)?;

    let ext = get_extension(output);

    if ext == ".mp4" {
        let result = serde_json::json!({
            "success": false,
            "output_path": null,
            "error": "MP4 does not support alpha channel. Use .webm or .mov for background removal."
        });
        return Ok(result.to_string());
    }

    let hex_color = parse_color_to_hex(color)?;

    let similarity = ((tolerance as f64) / 255.0).min(1.0).max(0.01);

    // Map edges (pixel count, e.g. 1–20) to colorkey's blend parameter (0.0–0.5).
    // colorkey blend feathers the transition region at the key colour boundary.
    // Values above ~0.3 start keying adjacent non-background colours, so we cap at 0.2.
    let blend = if edges > 0 {
        ((edges as f64) * 0.01).min(0.2_f64)
    } else {
        0.0
    };

    let mut filters: Vec<String> = Vec::new();

    // Single colorkey/chromakey filter — the correct approach.
    // Multiple chained colorkey filters do NOT accumulate transparency;
    // each one only sees the already-processed output of the previous.
    let filter_name = match method {
        "chromakey" => "chromakey",
        _ => "colorkey",
    };
    filters.push(format!(
        "{}=color='{}':similarity={:.4}:blend={:.4}",
        filter_name, hex_color, similarity, blend
    ));

    // edge_cleanup: a small gblur on the whole frame softens jagged key edges.
    // This is a best-effort approximation; true alpha-only erosion would need
    // alphaextract → morphology → alphamerge, which requires libavfilter morphology.
    if edge_cleanup > 0 {
        let sigma = ((edge_cleanup as f64) * 0.03).min(2.0_f64).max(0.1);
        filters.push(format!("gblur=sigma={:.2}", sigma));
    }

    if refine {
        let refine_sim = (refine_tolerance as f64) / 255.0;
        let refine_sim = refine_sim.max(0.01).min(1.0);

        // Add a second colorkey pass for refinement, with a very low blend for precision
        filters.push(format!(
            "colorkey=color={}:similarity={:.4}:blend=0.01", // Small blend for refinement
            hex_color, refine_sim
        ));
    }

    if ext == ".webm" {
        // Explicitly force alpha-aware format at the end of the filter chain.
        filters.push("format=yuva420p".to_string());
    } else if ext == ".mov" {
        filters.push("format=argb".to_string());
    }

    let filter = filters.join(",");

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

    let mut args: Vec<String> = vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-y".into(),
        "-i".into(),
        input.into(),
        "-vf".into(),
        filter,
    ];

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
