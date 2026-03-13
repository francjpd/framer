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
    auto_ranges: bool,
    num_ranges: u32,
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

    let similarity = (tolerance as f64) / 255.0;
    let similarity = similarity.min(1.0).max(0.01);

    let mut filters: Vec<String> = Vec::new();

    if auto_ranges && num_ranges > 1 {
        let mut range_filters = String::new();
        let base_similarity = similarity;

        for i in 0..num_ranges {
            let offset = (i as f64 - num_ranges as f64 / 2.0) * 0.05;
            let range_sim = (base_similarity + offset).max(0.01).min(1.0);

            let single_filter = match method {
                "chromakey" => format!(
                    "chromakey=color={}:similarity={:.2}:blend=0.1",
                    hex_color, range_sim
                ),
                _ => format!(
                    "colorkey=color={}:similarity={:.2}:blend=0.1",
                    hex_color, range_sim
                ),
            };

            if i == 0 {
                range_filters.push_str(&single_filter);
            } else {
                range_filters.push_str(&format!(",{},", single_filter));
            }
        }
        filters.push(range_filters);
    } else {
        let base_filter = match method {
            "chromakey" => format!(
                "chromakey=color={}:similarity={:.2}:blend=0.1",
                hex_color, similarity
            ),
            _ => format!(
                "colorkey=color={}:similarity={:.2}:blend=0.1",
                hex_color, similarity
            ),
        };
        filters.push(base_filter);
    }

    if edges > 0 {
        if method == "chromakey" {
            filters.push(format!("gblur=sigma={}", edges));
        } else {
            filters.push(format!(
                "split[rgb][alpha];[alpha]alphaextract,gblur=sigma={}[softedge];[rgb][softedge]alphamerge",
                edges
            ));
        }
    }

    if edge_cleanup > 0 {
        filters.push(format!(
            " erosion=kernel={}:iterations={},dilate=kernel={}:iterations={}",
            edge_cleanup, edge_cleanup, edge_cleanup, edge_cleanup
        ));
    }

    if refine {
        let refine_sim = (refine_tolerance as f64) / 255.0;
        let refine_sim = refine_sim.max(0.01).min(1.0);

        filters.push(format!(
            "colorkey=color={}:similarity={:.2}:blend=0.0",
            hex_color, refine_sim
        ));
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
