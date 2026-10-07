defmodule FramerWeb.ImageInfo do
  @moduledoc """
  Minimal, dependency-free image header reader.

  The editor needs the intrinsic size of an uploaded still so it can set the
  rig canvas. Phoenix ships no image library and the engine is not allowed to
  touch pixels over the Port, so we read the dimensions straight from the file
  header. PNG, JPEG, WebP, BMP and GIF are supported; anything else returns an
  error and the caller falls back to a default canvas.
  """

  @type info :: %{width: pos_integer(), height: pos_integer(), format: atom()}

  @spec read(binary()) :: {:ok, info()} | {:error, atom()}
  def read(binary) when is_binary(binary) do
    with :error <- png(binary),
         :error <- gif(binary),
         :error <- bmp(binary),
         :error <- webp(binary),
         :error <- jpeg(binary) do
      {:error, :unsupported_image}
    end
  end

  # PNG: 8-byte signature, then an IHDR chunk with big-endian width/height.
  defp png(
         <<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", width::32, height::32, _rest::binary>>
       )
       when width > 0 and height > 0 do
    {:ok, %{width: width, height: height, format: :png}}
  end

  defp png(_), do: :error

  # GIF: "GIF87a"/"GIF89a", then little-endian width/height.
  defp gif(
         <<"GIF", _version::binary-size(3), width::little-16, height::little-16, _rest::binary>>
       )
       when width > 0 and height > 0 do
    {:ok, %{width: width, height: height, format: :gif}}
  end

  defp gif(_), do: :error

  # BMP: "BM", then a DIB header with little-endian width/height at 18/22.
  defp bmp(
         <<"BM", _size::little-32, _reserved::binary-size(4), _offset::little-32, _dib::little-32,
           width::little-32, height::little-32, _rest::binary>>
       )
       when width > 0 do
    {:ok, %{width: width, height: abs(height), format: :bmp}}
  end

  defp bmp(_), do: :error

  # WebP: RIFF container; VP8X (extended) stores canvas size minus one, VP8
  # (lossy) stores it after the sync code.
  defp webp(<<"RIFF", _size::little-32, "WEBP", rest::binary>>) do
    case rest do
      <<"VP8X", _chunk_size::little-32, _flags::binary-size(4), w::little-24, h::little-24,
        _rest::binary>> ->
        {:ok, %{width: w + 1, height: h + 1, format: :webp}}

      <<"VP8 ", _chunk::little-32, _frame::binary-size(3), _sync::binary-size(3), w::little-16,
        h::little-16, _rest::binary>> ->
        {:ok, %{width: Bitwise.band(w, 0x3FFF), height: Bitwise.band(h, 0x3FFF), format: :webp}}

      _ ->
        :error
    end
  end

  defp webp(_), do: :error

  # JPEG: scan for a Start-Of-Frame marker (C0..CF except C4/C8/CC).
  defp jpeg(<<0xFF, 0xD8, rest::binary>>), do: jpeg_scan(rest)
  defp jpeg(_), do: :error

  defp jpeg_scan(<<0xFF, marker, rest::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] do
    case rest do
      <<_length::16, _precision, height::16, width::16, _rest::binary>>
      when width > 0 and height > 0 ->
        {:ok, %{width: width, height: height, format: :jpeg}}

      _ ->
        :error
    end
  end

  defp jpeg_scan(<<0xFF, 0xFF, rest::binary>>), do: jpeg_scan(<<0xFF, rest::binary>>)

  defp jpeg_scan(<<0xFF, marker, rest::binary>>) when marker not in [0x00, 0xD8, 0xD9] do
    case rest do
      <<length::16, tail::binary>> when length >= 2 and byte_size(tail) >= length - 2 ->
        <<_skip::binary-size(length - 2), next::binary>> = tail
        jpeg_scan(next)

      _ ->
        :error
    end
  end

  defp jpeg_scan(<<_byte, rest::binary>>), do: jpeg_scan(rest)
  defp jpeg_scan(<<>>), do: :error
end
