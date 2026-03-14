defmodule FramerCore.Rust do
  @moduledoc """
  Elixir wrapper for Rust NIFs.
  Returns {:ok, result} or {:error, reason} tuples.
  """

  use Rustler, otp_app: :framer_core, crate: "framer_rust"

  # Existing NIFs
  def get_video_info(_path), do: :erlang.nif_error(:nif_not_loaded)
  def process_chunk(_input, _output, _start, _end, _fps, _target_fps \\ nil, _hwaccel \\ nil), do: :erlang.nif_error(:nif_not_loaded)
  def transcode(_input, _output, _codec, _bitrate), do: :erlang.nif_error(:nif_not_loaded)
  def apply_filter(_input, _output, _filter), do: :erlang.nif_error(:nif_not_loaded)

  # New operation NIFs
  def boost_fps(_input, _output, _target_fps), do: :erlang.nif_error(:nif_not_loaded)

  def remove_bg(
        _input,
        _output,
        _color,
        _tolerance,
        _edges,
        _method,
        _auto_ranges \\ true,
        _num_ranges \\ 5,
        _edge_cleanup \\ 3,
        _refine \\ false,
        _refine_tolerance \\ 45,
        _refine_block_size \\ 32
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def create_loop(
        _input,
        _output,
        _method,
        _fade_color,
        _fade_frames,
        _morph_steps,
        _hold_frames,
        _blend_mode,
        _ramp_factor
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
