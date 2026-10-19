defmodule Autolaunch.LaunchDraft.ImageValidatorTest do
  @moduledoc """
  An upload's pixel count is read from its header and capped at 4096 by 4096
  before anything decodes it, so a small file cannot make the site decode a
  huge picture. The proof that nothing decoded is structural: no call reaches
  libvips (`Vix.Nif`, `Vix.Vips.Operation`) or zlib's inflate while the file is
  checked.
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias Autolaunch.CallRecord
  alias Autolaunch.LaunchDraft.ImageValidator

  @side 40_000

  test "PIXEL_CAP: a 40,000 by 40,000 interlaced PNG under 2 MB is refused from its header, never decoded" do
    png = interlaced_png(@side, @side)
    assert byte_size(png) < ImageValidator.maximum_bytes()

    {result, decoders} = decoder_calls(fn -> ImageValidator.validate(png, "image/png") end)

    assert result == {:error, :too_many_pixels}
    assert decoders == []
  end

  test "PIXEL_CAP: JPEG and WebP headers are capped the same way, a moving WebP counting every frame" do
    jpeg =
      <<0xFF, 0xD8, 0xFF, 0xC2, 17::16, 8, @side::16, @side::16, 3>> <> :binary.copy(<<0>>, 9)

    still = webp(chunk("VP8L", <<0x2F, 16_383 + (16_383 <<< 14)::little-32, 0>>))

    # A canvas of one pixel whose picture says 16,384 by 16,384.
    lying = webp(vp8x(1, 1) <> chunk("VP8L", <<0x2F, 16_383 + (16_383 <<< 14)::little-32, 0>>))

    # 2,000 by 2,000, nine frames: 36 million pixels decoded.
    frame = chunk("ANMF", :binary.copy(<<0>>, 16) <> chunk("VP8L", <<0x2F, 0::little-32, 0>>))
    moving = webp(vp8x(2_000, 2_000) <> String.duplicate(frame, 9))

    for {bytes, type} <- [
          {jpeg, "image/jpeg"},
          {still, "image/webp"},
          {lying, "image/webp"},
          {moving, "image/webp"}
        ] do
      assert {{:error, :too_many_pixels}, []} ==
               decoder_calls(fn -> ImageValidator.validate(bytes, type) end)
    end
  end

  # Also shows the call record above sees a decode when there is one.
  test "a normal picture still passes, decoded in full" do
    for {file, type} <- [{"launch-draft.jpg", "image/jpeg"}, {"launch-draft.png", "image/png"}] do
      bytes = File.read!("test/support/fixtures/" <> file)
      {result, decoders} = decoder_calls(fn -> ImageValidator.validate(bytes, type) end)

      assert result == {:ok, type}
      assert {Vix.Vips.Operation, :avg, 1} in decoders
    end
  end

  # Every call into libvips or zlib the calling process makes while `fun` runs.
  defp decoder_calls(fun) do
    patterns = [{Vix.Nif, :_, :_}, {Vix.Vips.Operation, :_, :_}, {:zlib, :_, :_}]
    {result, events} = CallRecord.during(self(), patterns, fun)
    {result, CallRecord.calls(events)}
  end

  # A complete grey, one-bit, Adam7-interlaced PNG of all-zero rows.
  defp interlaced_png(width, height) do
    passes = [
      {0, 0, 8, 8},
      {4, 0, 8, 8},
      {0, 4, 4, 8},
      {2, 0, 4, 4},
      {0, 2, 2, 4},
      {1, 0, 2, 2},
      {0, 1, 1, 2}
    ]

    raw =
      Enum.sum(
        for {x, y, step_x, step_y} <- passes,
            columns = span(width, x, step_x),
            rows = span(height, y, step_y),
            columns > 0,
            do: rows * (1 + div(columns + 7, 8))
      )

    header = <<width::32, height::32, 1, 0, 0, 0, 1>>

    <<137, "PNG\r\n", 26, 10>> <>
      png_chunk("IHDR", header) <> png_chunk("IDAT", zeros(raw)) <> png_chunk("IEND", <<>>)
  end

  defp span(total, start, _step) when total <= start, do: 0
  defp span(total, start, step), do: div(total - start + step - 1, step)

  # `count` zero bytes, deflated a mebibyte at a time.
  defp zeros(count) do
    stream = :zlib.open()
    :ok = :zlib.deflateInit(stream, 9)
    block = :binary.copy(<<0>>, 1_048_576)

    body =
      for size <- List.duplicate(1_048_576, div(count, 1_048_576)) ++ [rem(count, 1_048_576)],
          do: :zlib.deflate(stream, binary_part(block, 0, size))

    compressed = IO.iodata_to_binary([body, :zlib.deflate(stream, <<>>, :finish)])
    :zlib.close(stream)
    compressed
  end

  defp png_chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  defp webp(chunks), do: <<"RIFF", byte_size(chunks) + 4::little-32, "WEBP", chunks::binary>>

  defp vp8x(width, height),
    do: chunk("VP8X", <<2, 0, 0, 0, width - 1::little-24, height - 1::little-24>>)

  defp chunk(type, data) do
    padding = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>
    <<type::binary, byte_size(data)::little-32, data::binary, padding::binary>>
  end
end
