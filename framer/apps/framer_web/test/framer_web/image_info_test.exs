defmodule FramerWeb.ImageInfoTest do
  use ExUnit.Case, async: true

  alias FramerWeb.ImageInfo

  test "reads a PNG IHDR" do
    assert {:ok, %{width: 9, height: 4, format: :png}} =
             ImageInfo.read(FramerWebWeb.Fixtures.png(9, 4))
  end

  test "reads a GIF logical screen descriptor" do
    width = 12
    height = 7
    gif = "GIF89a" <> <<width::little-16, height::little-16>> <> <<0, 0, 0>>
    assert {:ok, %{width: ^width, height: ^height, format: :gif}} = ImageInfo.read(gif)
  end

  test "reads a BMP DIB header" do
    width = 20
    height = 10

    bmp =
      "BM" <>
        <<54::little-32, 0, 0, 0, 0, 54::little-32, 40::little-32, width::little-32,
          height::little-32>> <> <<0, 0, 0, 0, 0, 0, 0, 0>>

    assert {:ok, %{width: ^width, height: ^height, format: :bmp}} = ImageInfo.read(bmp)
  end

  test "reads a top-down BMP with a negative DIB height" do
    width = 20
    height = 10

    bmp =
      "BM" <>
        <<54::little-32, 0, 0, 0, 0, 54::little-32, 40::little-32, width::little-32,
          -height::little-signed-32>> <> <<0, 0, 0, 0, 0, 0, 0, 0>>

    assert {:ok, %{width: ^width, height: ^height, format: :bmp}} = ImageInfo.read(bmp)
  end

  test "reads an extended WebP VP8X canvas" do
    width = 640
    height = 480

    webp =
      "RIFF" <>
        <<0::little-32>> <>
        "WEBP" <>
        "VP8X" <>
        <<10::little-32>> <>
        <<0x10, 0, 0, 0>> <>
        <<width - 1::little-24, height - 1::little-24>>

    assert {:ok, %{width: ^width, height: ^height, format: :webp}} = ImageInfo.read(webp)
  end

  test "reads a JPEG SOF0 frame" do
    jpeg = <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x10, 0, 0, 0>>
    assert {:ok, %{width: 16, height: 8, format: :jpeg}} = ImageInfo.read(jpeg)
  end

  test "returns the oriented dimensions for a JPEG with EXIF orientation 6" do
    jpeg = jpeg_with_exif_orientation(400, 200, 6)
    assert {:ok, %{width: 200, height: 400, format: :jpeg}} = ImageInfo.read(jpeg)
  end

  test "returns the oriented dimensions for a JPEG with EXIF orientation 8" do
    jpeg = jpeg_with_exif_orientation(400, 200, 8)
    assert {:ok, %{width: 200, height: 400, format: :jpeg}} = ImageInfo.read(jpeg)
  end

  test "keeps dimensions for upright EXIF orientations" do
    for orientation <- [1, 2, 3, 4] do
      jpeg = jpeg_with_exif_orientation(400, 200, orientation)
      assert {:ok, %{width: 400, height: 200, format: :jpeg}} = ImageInfo.read(jpeg)
    end
  end

  test "reads a big-endian EXIF orientation 6" do
    jpeg = jpeg_with_exif_orientation(400, 200, 6, :big)
    assert {:ok, %{width: 200, height: 400, format: :jpeg}} = ImageInfo.read(jpeg)
  end

  test "reports unsupported data" do
    assert {:error, :unsupported_image} = ImageInfo.read("not an image")
  end

  # A synthetic JPEG segment stream (SOI + APP1 EXIF + SOF0 + EOI) carrying the
  # given orientation. The header reader only walks segments, so this exercises
  # the parser without shipping a binary fixture.
  defp jpeg_with_exif_orientation(width, height, orientation, endian \\ :little) do
    tiff = exif_tiff(orientation, endian)
    app1 = <<0xFF, 0xE1, byte_size("Exif\0\0" <> tiff) + 2::16>> <> "Exif\0\0" <> tiff

    sof0 =
      <<0xFF, 0xC0, 0x00, 0x11, 0x08, height::16, width::16, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

    <<0xFF, 0xD8>> <> app1 <> sof0 <> <<0xFF, 0xD9>>
  end

  defp exif_tiff(orientation, :little) do
    entry = <<0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, orientation::little-16, 0, 0>>
    <<0x49, 0x49, 0x2A, 0x00, 8::little-32, 1::little-16>> <> entry <> <<0::little-32>>
  end

  defp exif_tiff(orientation, :big) do
    entry = <<0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, orientation::big-16, 0, 0>>
    <<0x4D, 0x4D, 0x00, 0x2A, 8::big-32, 1::big-16>> <> entry <> <<0::big-32>>
  end
end
