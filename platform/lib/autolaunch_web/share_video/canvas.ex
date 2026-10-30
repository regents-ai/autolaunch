defmodule AutolaunchWeb.ShareVideo.Canvas do
  @moduledoc """
  What every share video is made with: 1080 by 1350, 30 frames a second, ten
  seconds, encoded as H.264 in yuv420p with its index at the front, so it
  plays as soon as it starts loading. A film (`AutolaunchWeb.ShareVideo.Film`
  for a launch, `AutolaunchWeb.ShareVideo.MarketFilm` for covered calls and
  After-hours Exposure) hands `render/1` one function that draws frame `index`;
  the frames go to ffmpeg, which runs at low priority so pages keep their share
  of the machine.
  """

  alias AutolaunchWeb.ShareCard.Draw
  alias Vix.Vips.{Image, Operation}

  @width 1080
  @height 1350
  @fps 30
  @frames 300

  @doc """
  The video's MP4 bytes from `frame`, a function from a frame's index to its
  image, with what drawing and encoding it took: the time in milliseconds,
  the MP4's bytes and the most memory the BEAM held while it ran.
  """
  @spec render((non_neg_integer() -> Vix.Vips.Image.t())) ::
          {:ok, binary(), map()} | {:error, term()}
  # The path is the site's own temporary file, never named by a request.
  # sobelow_skip ["Traversal.FileModule"]
  def render(frame) do
    started = System.monotonic_time(:millisecond)
    path = Path.join(System.tmp_dir!(), "share-video-#{System.unique_integer([:positive])}.mp4")

    try do
      with {:ok, peak} <- encode(frame, path),
           {:ok, mp4} <- File.read(path) do
        {:ok, mp4,
         %{
           ms: System.monotonic_time(:millisecond) - started,
           peak_bytes: peak,
           bytes: byte_size(mp4)
         }}
      end
    after
      File.rm(path)
    end
  end

  @doc "Words drawn in one of the card's fonts (`:bold`, `:regular`, `:pixel`) and a colour."
  def text!(words, weight, size, color) do
    {:ok, layer} = Draw.layer(words, weight, size, color)
    layer
  end

  @doc "Words drawn as `text!/4` draws them, cut short to `max` pixels wide."
  def fit!(words, weight, size, color, max) do
    {:ok, layer} = Draw.fit(words, weight, size, color, max)
    layer
  end

  @doc "A placed layer, `{image, x, y}`, at `opacity`."
  def faded({layer, x, y}, opacity) when opacity >= 1.0, do: {layer, x, y}

  def faded({layer, x, y}, opacity) do
    {:ok, alpha} = Operation.linear(layer, [1.0, 1.0, 1.0, opacity], [0.0, 0.0, 0.0, 0.0])
    {:ok, alpha} = Operation.cast(alpha, :VIPS_FORMAT_UCHAR)
    {alpha, x, y}
  end

  @doc "Every placed layer over `base` in one pass."
  def flat(base, []), do: base

  def flat(base, layers) do
    {:ok, image} =
      Operation.composite(
        [base | Enum.map(layers, &elem(&1, 0))],
        List.duplicate(:VIPS_BLEND_MODE_OVER, length(layers)),
        x: Enum.map(layers, &elem(&1, 1)),
        y: Enum.map(layers, &elem(&1, 2))
      )

    image
  end

  @doc "An SVG document drawn as an image."
  def svg!(svg) do
    {:ok, {image, _flags}} = Operation.svgload_buffer(svg)
    image
  end

  @doc """
  A figure in bold `color`, stepping down in size until it is at most `max`
  wide, and past its last step drawn at the size that fits: never cut short.
  """
  def figure(value, color, max, sizes \\ [50, 44, 38, 32, 28])

  def figure(value, color, max, [size | smaller]) do
    layer = text!(value, :bold, size, color)

    cond do
      Image.width(layer) <= max -> layer
      smaller != [] -> figure(value, color, max, smaller)
      true -> figure(value, color, max, [div(size * max, Image.width(layer))])
    end
  end

  @doc "A line's tip at frame `index`: a dot ringed on `field`, with a pulse once a second."
  def tip_svg(x, y, color, field, index) do
    phase = rem(index, @fps) / @fps

    """
    <circle cx="#{n(x)}" cy="#{n(y)}" r="#{n(9 + 16 * phase)}" fill="#{color}" opacity="#{n(0.45 * (1 - phase))}"/>
    <circle cx="#{n(x)}" cy="#{n(y)}" r="9" fill="#{color}" stroke="#{field}" stroke-width="3"/>
    """
  end

  @doc "How far frame `index` is from frame `from` to frame `to`, from 0.0 to 1.0."
  def progress(index, from, to), do: min(max((index - from) / (to - from), 0.0), 1.0)

  @doc "Progress eased in and out."
  def ease(p), do: -(:math.cos(:math.pi() * p) - 1) / 2

  @doc "A number as SVG writes a coordinate, to one decimal place."
  def n(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp pixels(image) do
    {:ok, rgb} = Operation.extract_band(image, 0, n: 3)
    {:ok, rgb} = Operation.cast(rgb, :VIPS_FORMAT_UCHAR)
    {:ok, bytes} = Image.write_to_binary(rgb)
    bytes
  end

  # Frames go to ffmpeg as raw RGB on its input, at low priority. A port
  # cannot close its input on its own, so `head` passes on exactly the
  # frames' bytes and then closes ffmpeg's input, and ffmpeg writes the file
  # and exits. The highest memory the BEAM reached is kept for the
  # measurement.
  defp encode(frame, path) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args:
          ["-c", ~s|head -c "$0" \| nice -n 10 "$@"|, "#{@frames * @width * @height * 3}"] ++
            ffmpeg(path)
      ])

    peak =
      Enum.reduce(0..(@frames - 1), 0, fn index, peak ->
        true = Port.command(port, index |> frame.() |> pixels())
        max(peak, :erlang.memory(:total))
      end)

    finished(port, peak, [])
  end

  defp finished(port, peak, said) do
    receive do
      {^port, {:data, words}} ->
        finished(port, peak, [words | said])

      {^port, {:exit_status, 0}} ->
        {:ok, peak}

      {^port, {:exit_status, status}} ->
        {:error, {:ffmpeg, status, said |> Enum.reverse() |> IO.iodata_to_binary()}}
    after
      120_000 ->
        Port.close(port)
        {:error, :ffmpeg_timeout}
    end
  end

  defp ffmpeg(path),
    do: [
      System.find_executable("ffmpeg"),
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgb24",
      "-s",
      "#{@width}x#{@height}",
      "-r",
      "#{@fps}",
      "-i",
      "pipe:0",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "21",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      "-threads",
      "1",
      "-y",
      path
    ]
end
