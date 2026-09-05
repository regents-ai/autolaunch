defmodule Autolaunch.LaunchDraft.ImageValidator do
  @moduledoc false

  import Bitwise

  @maximum_bytes 2_097_152
  @content_types ["image/png", "image/jpeg", "image/webp"]
  @png_signature <<137, "PNG\r\n", 26, 10>>
  @jpeg_start <<255, 216>>
  @jpeg_frames [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec validate(binary(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate(bytes, declared_type)
      when is_binary(bytes) and declared_type in @content_types and
             byte_size(bytes) in 1..@maximum_bytes do
    if structurally_complete?(bytes, declared_type) and decodes_completely?(bytes, declared_type),
      do: {:ok, declared_type},
      else: {:error, :invalid_image}
  end

  def validate(bytes, _declared_type) when is_binary(bytes) and byte_size(bytes) > @maximum_bytes,
    do: {:error, :image_too_large}

  def validate(_bytes, _declared_type), do: {:error, :invalid_image}

  defp structurally_complete?(<<@png_signature, rest::binary>>, "image/png") do
    png_chunks(rest, %{ihdr: nil, palette?: false, idat: [], phase: :header})
  end

  defp structurally_complete?(<<@jpeg_start, rest::binary>>, "image/jpeg") do
    jpeg_markers(rest, %{dqt: MapSet.new(), dht: MapSet.new(), frame: nil, scans: 0})
  end

  defp structurally_complete?(
         <<"RIFF", declared_size::little-32, "WEBP", chunks::binary>> = bytes,
         "image/webp"
       ),
       do: declared_size + 8 == byte_size(bytes) and webp_chunks(chunks, false)

  defp structurally_complete?(_bytes, _declared_type), do: false

  # libvips performs the decoder-level proof that container parsing cannot:
  # the strict format-specific loader rejects damaged data and `avg/1` pulls
  # every pixel through the sequential pipeline. This keeps evaluation bounded
  # without imposing a width, height, aspect-ratio, crop, or resize policy.
  defp decodes_completely?(bytes, declared_type) do
    with {:ok, {image, _flags}} <- decode(bytes, declared_type),
         {:ok, _average} <- Vix.Vips.Operation.avg(image) do
      true
    else
      _error -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp decode(bytes, "image/png"),
    do: Vix.Vips.Operation.pngload_buffer(bytes, decode_options())

  defp decode(bytes, "image/jpeg"),
    do: Vix.Vips.Operation.jpegload_buffer(bytes, decode_options())

  defp decode(bytes, "image/webp"),
    do: Vix.Vips.Operation.webpload_buffer(bytes, [{:n, -1} | decode_options()])

  defp decode_options,
    do: [access: :VIPS_ACCESS_SEQUENTIAL, "fail-on": :VIPS_FAIL_ON_WARNING]

  # PNG validation checks every chunk CRC and ordering rule, then safely inflates
  # the image stream and consumes exactly the scanlines described by IHDR. The
  # scanline consumer discards output as it goes, so a small compressed payload
  # cannot become an unbounded in-memory binary.
  defp png_chunks(<<length::32, type::binary-size(4), rest::binary>>, state)
       when byte_size(rest) >= length + 4 do
    <<data::binary-size(length), expected_crc::32, tail::binary>> = rest

    if :erlang.crc32(type <> data) == expected_crc do
      png_chunk(type, data, tail, state)
    else
      false
    end
  end

  defp png_chunks(_truncated, _state), do: false

  defp png_chunk("IHDR", data, tail, %{phase: :header, ihdr: nil} = state) do
    case png_header(data) do
      {:ok, header} -> png_chunks(tail, %{state | ihdr: header, phase: :before_idat})
      :error -> false
    end
  end

  defp png_chunk("PLTE", data, tail, %{phase: :before_idat} = state)
       when byte_size(data) in 3..768 and rem(byte_size(data), 3) == 0,
       do: png_chunks(tail, %{state | palette?: true})

  defp png_chunk("IDAT", data, tail, %{phase: phase, ihdr: header} = state)
       when phase in [:before_idat, :idat] and not is_nil(header) and byte_size(data) > 0,
       do: png_chunks(tail, %{state | idat: [data | state.idat], phase: :idat})

  defp png_chunk("IEND", <<>>, <<>>, %{phase: phase, ihdr: header, idat: idat} = state)
       when phase in [:idat, :after_idat] and idat != [] do
    palette_valid? = header.color_type != 3 or state.palette?
    palette_valid? and valid_png_payload?(header, idat |> Enum.reverse() |> IO.iodata_to_binary())
  end

  defp png_chunk(<<first, _::binary>> = type, _data, tail, %{phase: phase} = state)
       when phase in [:before_idat, :idat, :after_idat] and band(first, 0x20) != 0 do
    next_phase = if phase == :idat, do: :after_idat, else: phase

    if type in ["IHDR", "PLTE", "IDAT", "IEND"],
      do: false,
      else: png_chunks(tail, %{state | phase: next_phase})
  end

  defp png_chunk(_type, _data, _tail, _state), do: false

  defp png_header(<<width::32, height::32, depth, color_type, compression, filter, interlace>>)
       when width > 0 and height > 0 and compression == 0 and filter == 0 and interlace in [0, 1] do
    channels = %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}
    depths = %{0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16]}

    if depth in Map.get(depths, color_type, []) do
      {:ok,
       %{
         width: width,
         height: height,
         depth: depth,
         color_type: color_type,
         channels: Map.fetch!(channels, color_type),
         interlace: interlace
       }}
    else
      :error
    end
  end

  defp png_header(_data), do: :error

  defp valid_png_payload?(header, compressed) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream)
      valid? = inflate_png(stream, compressed, png_scan_state(header))
      :ok = :zlib.inflateEnd(stream)
      valid?
    catch
      _kind, _reason -> false
    after
      :zlib.close(stream)
    end
  end

  defp inflate_png(stream, input, state) do
    case :zlib.safeInflate(stream, input) do
      {:continue, output} ->
        case consume_png_output(IO.iodata_to_binary(output), state) do
          {:ok, next} -> inflate_png(stream, [], next)
          :error -> false
        end

      {:finished, output} ->
        case consume_png_output(IO.iodata_to_binary(output), state) do
          {:ok, next} -> png_scan_complete?(next)
          :error -> false
        end

      {:need_dictionary, _adler, _output} ->
        false
    end
  end

  defp png_scan_state(%{interlace: 0} = header) do
    %{passes: [{png_row_bytes(header.width, header), header.height}], row_bytes: 0}
  end

  defp png_scan_state(%{interlace: 1} = header) do
    passes =
      [
        {0, 0, 8, 8},
        {4, 0, 8, 8},
        {0, 4, 4, 8},
        {2, 0, 4, 4},
        {0, 2, 2, 4},
        {1, 0, 2, 2},
        {0, 1, 1, 2}
      ]
      |> Enum.map(fn {start_x, start_y, step_x, step_y} ->
        width = pass_size(header.width, start_x, step_x)
        height = pass_size(header.height, start_y, step_y)
        {png_row_bytes(width, header), height}
      end)
      |> Enum.reject(fn {_bytes, rows} -> rows == 0 end)

    %{passes: passes, row_bytes: 0}
  end

  defp png_row_bytes(width, header),
    do: div(width * header.channels * header.depth + 7, 8)

  defp pass_size(total, start, _step) when total <= start, do: 0
  defp pass_size(total, start, step), do: div(total - start + step - 1, step)

  defp consume_png_output(<<>>, state), do: {:ok, normalize_png_passes(state)}

  defp consume_png_output(data, %{row_bytes: remaining} = state) when remaining > 0 do
    consumed = min(byte_size(data), remaining)
    <<_discard::binary-size(consumed), tail::binary>> = data
    consume_png_output(tail, %{state | row_bytes: remaining - consumed})
  end

  defp consume_png_output(<<filter, tail::binary>>, %{row_bytes: 0} = state)
       when filter in 0..4 do
    case normalize_png_passes(state) do
      %{passes: [{bytes, rows} | rest]} = normalized when rows > 0 ->
        next_passes = if rows == 1, do: rest, else: [{bytes, rows - 1} | rest]
        consume_png_output(tail, %{normalized | passes: next_passes, row_bytes: bytes})

      _complete ->
        :error
    end
  end

  defp consume_png_output(_invalid_filter_or_extra, _state), do: :error

  defp normalize_png_passes(%{row_bytes: 0, passes: [{_bytes, 0} | rest]} = state),
    do: normalize_png_passes(%{state | passes: rest})

  defp normalize_png_passes(state), do: state

  defp png_scan_complete?(state) do
    %{passes: passes, row_bytes: remaining} = normalize_png_passes(state)
    passes == [] and remaining == 0
  end

  # JPEG validation accepts baseline and progressive frames. It validates the
  # quantization/Huffman tables, frame component layout, every scan header,
  # byte stuffing/restart markers, and an exact terminal EOI rather than merely
  # looking for SOI/SOF/SOS marker bytes.
  defp jpeg_markers(<<255, rest::binary>>, state), do: jpeg_marker_prefix(rest, state)
  defp jpeg_markers(_invalid, _state), do: false

  defp jpeg_marker_prefix(<<255, rest::binary>>, state), do: jpeg_marker_prefix(rest, state)
  defp jpeg_marker_prefix(<<marker, rest::binary>>, state), do: jpeg_marker(marker, rest, state)
  defp jpeg_marker_prefix(<<>>, _state), do: false

  defp jpeg_marker(0xD9, <<>>, %{frame: frame, scans: scans}),
    do: not is_nil(frame) and scans > 0

  defp jpeg_marker(marker, rest, state)
       when marker in 0xE0..0xEF or marker == 0xFE,
       do: jpeg_segment(rest, state, &jpeg_markers_after_segment/2)

  defp jpeg_marker(0xDB, rest, state),
    do: jpeg_segment(rest, state, &jpeg_quantization/2)

  defp jpeg_marker(0xC4, rest, state),
    do: jpeg_segment(rest, state, &jpeg_huffman/2)

  defp jpeg_marker(marker, rest, state) when marker in @jpeg_frames,
    do: jpeg_segment(rest, state, &jpeg_frame(marker, &1, &2))

  defp jpeg_marker(0xDA, rest, state),
    do: jpeg_segment(rest, state, &jpeg_scan_header/2)

  defp jpeg_marker(0xDD, rest, state),
    do:
      jpeg_segment(rest, state, fn data, current ->
        match?(<<_::16>>, data) and {:next, current}
      end)

  defp jpeg_marker(_unknown_or_out_of_order, _rest, _state), do: false

  defp jpeg_segment(<<length::16, rest::binary>>, state, handler)
       when length >= 2 and byte_size(rest) >= length - 2 do
    <<data::binary-size(length - 2), tail::binary>> = rest

    case handler.(data, state) do
      {:next, next_state} -> jpeg_markers(tail, next_state)
      {:scan, next_state} -> jpeg_entropy(tail, false, next_state)
      _invalid -> false
    end
  end

  defp jpeg_segment(_truncated, _state, _handler), do: false
  defp jpeg_markers_after_segment(_data, state), do: {:next, state}

  defp jpeg_quantization(data, state) do
    case jpeg_quantization_tables(data, state.dqt) do
      {:ok, tables} -> {:next, %{state | dqt: tables}}
      :error -> false
    end
  end

  defp jpeg_quantization_tables(<<>>, tables), do: {:ok, tables}

  defp jpeg_quantization_tables(<<precision::4, id::4, rest::binary>>, tables)
       when precision in [0, 1] and id <= 3 do
    bytes = 64 * (precision + 1)

    if byte_size(rest) >= bytes do
      <<_table::binary-size(bytes), tail::binary>> = rest
      jpeg_quantization_tables(tail, MapSet.put(tables, id))
    else
      :error
    end
  end

  defp jpeg_quantization_tables(_invalid, _tables), do: :error

  defp jpeg_huffman(data, state) do
    case jpeg_huffman_tables(data, state.dht) do
      {:ok, tables} -> {:next, %{state | dht: tables}}
      :error -> false
    end
  end

  defp jpeg_huffman_tables(<<>>, tables), do: {:ok, tables}

  defp jpeg_huffman_tables(<<class::4, id::4, counts::binary-size(16), rest::binary>>, tables)
       when class in [0, 1] and id <= 3 do
    symbols = counts |> :binary.bin_to_list() |> Enum.sum()

    if symbols in 1..256 and byte_size(rest) >= symbols do
      <<_symbols::binary-size(symbols), tail::binary>> = rest
      jpeg_huffman_tables(tail, MapSet.put(tables, {class, id}))
    else
      :error
    end
  end

  defp jpeg_huffman_tables(_invalid, _tables), do: :error

  defp jpeg_frame(_marker, _data, %{frame: frame}) when not is_nil(frame), do: false

  defp jpeg_frame(marker, data, state) do
    with {:ok, parsed} <- jpeg_frame_components(data),
         ids <- Enum.map(parsed, &elem(&1, 0)),
         true <- Enum.uniq(ids) == ids,
         true <- valid_frame_tables?(parsed, state.dqt) do
      frame = %{marker: marker, components: MapSet.new(ids)}
      {:next, %{state | frame: frame}}
    else
      _invalid -> false
    end
  end

  defp jpeg_frame_components(<<precision, height::16, width::16, count, components::binary>>) do
    if precision in [8, 12] and width > 0 and height > 0 and count in 1..4 and
         byte_size(components) == count * 3 do
      {:ok,
       for <<id, horizontal::4, vertical::4, quantization <- components>> do
         {id, horizontal, vertical, quantization}
       end}
    else
      :error
    end
  end

  defp jpeg_frame_components(_invalid), do: :error

  defp valid_frame_tables?(parsed, tables) do
    Enum.all?(parsed, fn {_id, horizontal, vertical, quantization} ->
      horizontal in 1..4 and vertical in 1..4 and MapSet.member?(tables, quantization)
    end)
  end

  defp jpeg_scan_header(_data, %{frame: nil}), do: false

  defp jpeg_scan_header(data, state) do
    with {:ok, parsed, start, finish, high, low} <- jpeg_scan_components(data),
         true <- scan_components_belong_to_frame?(parsed, state.frame.components),
         true <- valid_jpeg_scan?(state.frame.marker, parsed, start, finish, high, low, state.dht) do
      {:scan, %{state | scans: state.scans + 1}}
    else
      _invalid -> false
    end
  end

  defp jpeg_scan_components(<<count, rest::binary>>)
       when count in 1..4 and byte_size(rest) == count * 2 + 3 do
    component_bytes = count * 2
    <<components::binary-size(component_bytes), start, finish, high::4, low::4>> = rest
    {:ok, for(<<id, dc::4, ac::4 <- components>>, do: {id, dc, ac}), start, finish, high, low}
  end

  defp jpeg_scan_components(_invalid), do: :error

  defp scan_components_belong_to_frame?(parsed, frame_components) do
    ids = Enum.map(parsed, &elem(&1, 0))

    Enum.uniq(ids) == ids and
      Enum.all?(ids, &MapSet.member?(frame_components, &1))
  end

  defp valid_jpeg_scan?(0xC2, parsed, start, finish, high, low, tables),
    do: progressive_scan?(parsed, start, finish, high, low, tables)

  defp valid_jpeg_scan?(_baseline, parsed, 0, 63, 0, 0, tables) do
    Enum.all?(parsed, fn {_id, dc, ac} ->
      MapSet.member?(tables, {0, dc}) and MapSet.member?(tables, {1, ac})
    end)
  end

  defp valid_jpeg_scan?(_marker, _parsed, _start, _finish, _high, _low, _tables), do: false

  defp progressive_scan?(parsed, 0, 0, high, low, tables) do
    high <= 13 and low <= 13 and (high == 0 or high == low + 1) and
      Enum.all?(parsed, fn {_id, dc, _ac} -> MapSet.member?(tables, {0, dc}) end)
  end

  defp progressive_scan?([_one] = parsed, start, finish, high, low, tables)
       when start in 1..63 and finish >= start and finish <= 63 do
    high <= 13 and low <= 13 and (high == 0 or high == low + 1) and
      Enum.all?(parsed, fn {_id, _dc, ac} -> MapSet.member?(tables, {1, ac}) end)
  end

  defp progressive_scan?(_parsed, _start, _finish, _high, _low, _tables), do: false

  defp jpeg_entropy(<<255, 0, rest::binary>>, _seen_data, state),
    do: jpeg_entropy(rest, true, state)

  defp jpeg_entropy(<<255, marker, rest::binary>>, seen_data, state)
       when marker in 0xD0..0xD7,
       do: jpeg_entropy(rest, seen_data, state)

  defp jpeg_entropy(<<255, 255, rest::binary>>, seen_data, state),
    do: jpeg_entropy(<<255, rest::binary>>, seen_data, state)

  defp jpeg_entropy(<<255, marker, rest::binary>>, true, state),
    do: jpeg_marker(marker, rest, state)

  defp jpeg_entropy(<<_byte, rest::binary>>, _seen_data, state),
    do: jpeg_entropy(rest, true, state)

  defp jpeg_entropy(_truncated_or_empty, _seen_data, _state), do: false

  # WebP validation checks the real VP8/VP8L uncompressed headers (or the
  # corresponding nested frame header for animation) and exact RIFF padding.
  defp webp_chunks(<<>>, seen_image), do: seen_image

  defp webp_chunks(<<type::binary-size(4), length::little-32, rest::binary>>, seen_image)
       when byte_size(rest) >= length + rem(length, 2) do
    <<data::binary-size(length), padding::binary-size(rem(length, 2)), tail::binary>> = rest

    padding in [<<>>, <<0>>] and webp_chunk(type, data, tail, seen_image)
  end

  defp webp_chunks(_truncated, _seen_image), do: false

  defp webp_chunk("VP8 ", data, tail, _seen_image),
    do: valid_vp8?(data) and webp_chunks(tail, true)

  defp webp_chunk("VP8L", data, tail, _seen_image),
    do: valid_vp8l?(data) and webp_chunks(tail, true)

  defp webp_chunk("VP8X", data, tail, seen_image),
    do: valid_vp8x?(data) and webp_chunks(tail, seen_image)

  defp webp_chunk("ANMF", data, tail, _seen_image),
    do: valid_anmf?(data) and webp_chunks(tail, true)

  defp webp_chunk(metadata, data, tail, seen_image)
       when metadata in ["ICCP", "EXIF", "XMP ", "ALPH", "ANIM"],
       do: data != <<>> and webp_chunks(tail, seen_image)

  defp webp_chunk(_unknown, _data, _tail, _seen_image), do: false

  defp valid_vp8?(
         <<first, second, third, 0x9D, 0x01, 0x2A, width::little-16, height::little-16,
           rest::binary>>
       ) do
    tag = first + (second <<< 8) + (third <<< 16)
    partition = tag >>> 5

    band(tag, 1) == 0 and partition > 0 and partition <= byte_size(rest) + 7 and
      band(width, 0x3FFF) > 0 and band(height, 0x3FFF) > 0 and rest != <<>>
  end

  defp valid_vp8?(_data), do: false

  defp valid_vp8l?(<<0x2F, bits::little-32, rest::binary>>) do
    width = band(bits, 0x3FFF) + 1
    height = band(bits >>> 14, 0x3FFF) + 1
    version = band(bits >>> 29, 0x7)
    width > 0 and height > 0 and version == 0 and rest != <<>>
  end

  defp valid_vp8l?(_data), do: false

  defp valid_vp8x?(
         <<flags, reserved::binary-size(3), _width_minus_one::little-24,
           _height_minus_one::little-24>>
       ),
       do: band(flags, 0xC1) == 0 and reserved == <<0, 0, 0>>

  defp valid_vp8x?(_data), do: false

  defp valid_anmf?(
         <<_x::little-24, _y::little-24, _width::little-24, _height::little-24,
           _duration::little-24, flags, nested::binary>>
       ),
       do: band(flags, 0xFC) == 0 and webp_chunks(nested, false)

  defp valid_anmf?(_data), do: false
end
