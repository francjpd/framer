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
           width::little-32, height::little-signed-32, _rest::binary>>
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

  # JPEG: walk the pre-SOF segment stream for a Start-Of-Frame marker (C0..CF
  # except C4/C8/CC, the unrotated pixel dimensions) and any APP1 EXIF
  # orientation. Browsers apply EXIF orientation when decoding a still, so the
  # canvas must report the *displayed* (oriented) dimensions - otherwise the
  # editor's letterboxing and click mapping diverge from the image the user
  # sees, which is the reported "bone does not start where the pointer is"
  # defect on phone photographs.
  defp jpeg(<<0xFF, 0xD8, rest::binary>>) do
    case jpeg_scan(rest, 1) do
      {:ok, width, height, orientation} when width > 0 and height > 0 ->
        {width, height} = orient_dimensions(width, height, orientation)
        {:ok, %{width: width, height: height, format: :jpeg}}

      _ ->
        :error
    end
  end

  defp jpeg(_), do: :error

  # SOF markers (frame header): precision(1) height(2) width(2) after length.
  defp jpeg_scan(<<0xFF, marker, rest::binary>>, orientation)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] do
    case rest do
      <<length::16, _precision, height::16, width::16, _tail::binary>>
      when length >= 7 and width > 0 and height > 0 ->
        {:ok, width, height, orientation}

      _ ->
        :error
    end
  end

  # APP1 (EXIF): "Exif\0\0" then a TIFF header carrying the orientation tag.
  defp jpeg_scan(<<0xFF, 0xE1, rest::binary>>, orientation) do
    case rest do
      <<length::16, seg::binary-size(length - 2), next::binary>> when length >= 2 ->
        jpeg_scan(next, exif_orientation(seg) || orientation)

      _ ->
        :error
    end
  end

  # 0xFF fill byte before the real marker.
  defp jpeg_scan(<<0xFF, 0xFF, rest::binary>>, orientation),
    do: jpeg_scan(<<0xFF, rest::binary>>, orientation)

  # Standalone markers carry no length field: TEM, RSTn, SOI, EOI.
  defp jpeg_scan(<<0xFF, marker, rest::binary>>, orientation)
       when marker in [0x01, 0xD8, 0xD9] or marker in 0xD0..0xD7 do
    jpeg_scan(rest, orientation)
  end

  # Skip any other segment by its length; 0xFF 0x00 (stuffed data) is only
  # valid inside entropy-coded data, so it marks a malformed pre-SOF stream.
  defp jpeg_scan(<<0xFF, marker, rest::binary>>, orientation) when marker != 0x00 do
    case rest do
      <<length::16, tail::binary>> when length >= 2 and byte_size(tail) >= length - 2 ->
        <<_skip::binary-size(length - 2), next::binary>> = tail
        jpeg_scan(next, orientation)

      _ ->
        :error
    end
  end

  defp jpeg_scan(_other, _orientation), do: :error

  # EXIF orientation (1..8) from a JPEG APP1 payload, or nil when absent.
  defp exif_orientation(<<"Exif", 0, 0, tiff::binary>>), do: tiff_orientation(tiff)
  defp exif_orientation(_), do: nil

  defp tiff_orientation(tiff) do
    case tiff do
      <<0x49, 0x49, 0x2A, 0x00, offset::little-32, _::binary>> ->
        ifd0_orientation(tiff, offset, :little)

      <<0x4D, 0x4D, 0x00, 0x2A, offset::big-32, _::binary>> ->
        ifd0_orientation(tiff, offset, :big)

      _ ->
        nil
    end
  end

  defp ifd0_orientation(tiff, offset, :little) do
    with true <- offset + 2 <= byte_size(tiff),
         <<count::little-16>> <- binary_part(tiff, offset, 2) do
      entries = binary_part(tiff, offset + 2, byte_size(tiff) - offset - 2)
      find_orientation_little(entries, count)
    else
      _ -> nil
    end
  end

  defp ifd0_orientation(tiff, offset, :big) do
    with true <- offset + 2 <= byte_size(tiff),
         <<count::big-16>> <- binary_part(tiff, offset, 2) do
      entries = binary_part(tiff, offset + 2, byte_size(tiff) - offset - 2)
      find_orientation_big(entries, count)
    else
      _ -> nil
    end
  end

  defp find_orientation_little(_entries, 0), do: nil

  defp find_orientation_little(entries, count) do
    case entries do
      <<0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, value::little-16, 0, 0, _rest::binary>> ->
        value

      <<_entry::binary-size(12), rest::binary>> ->
        find_orientation_little(rest, count - 1)

      _ ->
        nil
    end
  end

  defp find_orientation_big(_entries, 0), do: nil

  defp find_orientation_big(entries, count) do
    case entries do
      <<0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, value::big-16, 0, 0, _rest::binary>> ->
        value

      <<_entry::binary-size(12), rest::binary>> ->
        find_orientation_big(rest, count - 1)

      _ ->
        nil
    end
  end

  # EXIF orientations 5..8 rotate the frame 90 degrees, swapping width/height.
  defp orient_dimensions(width, height, orientation) when orientation in [5, 6, 7, 8],
    do: {height, width}

  defp orient_dimensions(width, height, _orientation), do: {width, height}
end
