defmodule FramerWebWeb.Fixtures do
  @moduledoc """
  Test helpers: a dependency-free PNG encoder and rig builders.

  `png/3` builds a real, decodable RGBA PNG (OpenCV/FFmpeg can read it) so the
  editor's integration tests can exercise the whole path without shipping a
  binary fixture.
  """

  alias FramerWeb.Rig

  @doc "Build a solid-colour RGBA PNG of the given size."
  def png(width, height, color \\ {40, 120, 200, 255}) do
    {r, g, b, a} = color
    pixel = <<r, g, b, a>>
    scanline = <<0>> <> :binary.copy(pixel, width)
    raw = :binary.copy(scanline, height)
    idat = :zlib.compress(raw)

    signature = <<0x89, "PNG\r\n", 0x1A, "\n">>
    ihdr = <<width::32, height::32, 8, 6, 0, 0, 0>>

    signature <> chunk("IHDR", ihdr) <> chunk("IDAT", idat) <> chunk("IEND", "")
  end

  @doc """
  A minimal, decodable PNG with a subject block on a transparent field.

  The subject colour defaults to a saturated blue; the browser preview suite
  passes a saturated red so its screenshots match the slice spec's
  "red-block-on-transparent" fixture.
  """
  def png_with_subject(width \\ 64, height \\ 64, subject \\ {0, 0, 255, 255}) do
    {r, g, b, a} = subject

    # Build scanlines directly: transparent except the subject block in the middle.
    x0 = div(width, 4)
    x1 = width - x0
    y0 = div(height, 4)
    y1 = height - y0

    clear = :binary.copy(<<0, 0, 0, 0>>, width)

    subject_row =
      :binary.copy(<<0, 0, 0, 0>>, x0) <>
        :binary.copy(<<r, g, b, a>>, x1 - x0) <>
        :binary.copy(<<0, 0, 0, 0>>, width - x1)

    subject_row = <<0>> <> subject_row

    row_for = fn y -> if y >= y0 and y < y1, do: subject_row, else: <<0>> <> clear end
    raw = Enum.map_join(0..(height - 1), &row_for.(&1))

    idat = :zlib.compress(raw)
    signature = <<0x89, "PNG\r\n", 0x1A, "\n">>
    ihdr = <<width::32, height::32, 8, 6, 0, 0, 0>>

    signature <> chunk("IHDR", ihdr) <> chunk("IDAT", idat) <> chunk("IEND", "")
  end

  @doc "A rig with one horizontal bone through the middle of a `size` canvas."
  def simple_rig(size \\ 64) do
    rig = Rig.new(size, size, name: "Fixture rig")

    {rig, _id} =
      Rig.add_bone(rig, [div(size, 2), div(size, 2)], [div(size, 2), div(size, 4)],
        name: "root",
        radius: size / 2
      )

    Rig.auto_bind(rig)
  end

  @doc """
  A rig with no bones yet - a freshly created still before any skeleton is
  drawn. `RigStore.save/1` accepts it because saving validates with
  `allow_empty_bones: true`.
  """
  def zero_bone_rig(size \\ 64) do
    Rig.new(size, size, name: "Zero-bone fixture rig")
  end

  defp chunk(type, data) do
    crc = :erlang.crc32(type <> data)
    <<byte_size(data)::32, type::binary, data::binary, crc::32>>
  end
end
