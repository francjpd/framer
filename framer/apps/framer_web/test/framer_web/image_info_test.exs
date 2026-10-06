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

  test "reads an extended WebP VP8X canvas" do
    width = 18
    height = 9

    webp =
      "RIFF" <>
        <<0::little-32>> <>
        "WEBP" <>
        "VP8X" <> <<0, 0, 0, 0>> <> <<width - 1::little-24, height - 1::little-24>> <> <<0>>

    assert {:ok, %{width: ^width, height: ^height, format: :webp}} = ImageInfo.read(webp)
  end

  test "reads a JPEG SOF0 frame" do
    jpeg = <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x10, 0, 0, 0>>
    assert {:ok, %{width: 16, height: 8, format: :jpeg}} = ImageInfo.read(jpeg)
  end

  test "reports unsupported data" do
    assert {:error, :unsupported_image} = ImageInfo.read("not an image")
  end
end
