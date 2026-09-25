defmodule AutolaunchWeb.TokenDisplay do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Stocks.Amounts

  # Only production-sized supply figures are too wide for a summary row, so only
  # they are shortened. The mantissa is truncated, never rounded up.
  @scales [{Decimal.new(1_000_000_000), "B"}, {Decimal.new(1_000_000), "M"}]

  attr :amount, :string, default: nil
  attr :unit, :string, required: true

  @doc """
  A read-only token amount. A wide figure is shortened on screen while the exact
  amount stays readable to assistive technology and on hover. Never an input.
  """
  def amount(%{amount: nil} = assigns) do
    ~H"""
    —
    """
  end

  def amount(assigns) do
    assigns
    |> assign(exact: assigns.amount, shown: compact(assigns.amount))
    |> figure()
  end

  @significant_digits 4

  attr :amount, :string, default: nil
  attr :unit, :string, default: nil
  attr :fallback, :string, default: "No price yet"

  attr :round, :atom,
    default: :nearest,
    values: [:nearest, :down],
    doc: ":down for a figure that must never read higher than it is"

  @doc """
  A read-only price. A price carrying more than four significant digits is
  shortened, rounded to the nearest, and a long run of zeros after the point is
  written as a count on screen, as in `0.0₇44`, while the same short figure
  with its zeros written out stays readable to assistive technology and on
  hover. An amount that is not a plain decimal is shown as written.
  """
  def price(%{amount: amount} = assigns) when is_nil(amount) or amount == "" do
    ~H"""
    {@fallback}
    """
  end

  def price(assigns) do
    short = significant(assigns.amount, assigns.round)

    assigns
    |> assign(exact: short, shown: zeros(short))
    |> figure()
  end

  @doc "A plain decimal cut to four significant digits, as `price/1` shows it, as text."
  def short(amount, round \\ :nearest), do: significant(amount, round)

  # Four or more zeros straight after the point are hard to count, so the run
  # is written as one zero with its length below it: 0.0000000444 is 0.0₇444.
  @zero_run ~r/(?<![\d.])0\.(0{4,})(\d+)/

  @doc "Text with each small figure's zeros after the point counted, as in `0.0₇444 REGENT`."
  def zeros(text),
    do:
      Regex.replace(@zero_run, text, fn _all, run, rest ->
        "0.0#{subscript(byte_size(run))}#{rest}"
      end)

  defp subscript(count),
    do: count |> Integer.digits() |> Enum.map_join(&<<0x2080 + &1::utf8>>)

  attr :amount, :string, required: true
  attr :unit, :string, default: nil

  @doc """
  A read-only price shown with every digit it was given, only its zeros after
  the point counted. The plain figure stays readable to assistive technology
  and on hover.
  """
  def counted(assigns) do
    assigns
    |> assign(exact: assigns.amount, shown: zeros(assigns.amount))
    |> figure()
  end

  attr :amount, :string, required: true
  attr :unit, :string, default: nil

  @doc """
  A read-only token amount read from the chain, cut to four significant digits
  and never rounded up, its whole part grouped in thousands and a long run of
  zeros after the point counted, as in `94,450,000` or `0.0₆412`. The exact
  amount stays readable to assistive technology and on hover.
  """
  def tokens(assigns) do
    shown = assigns.amount |> significant(:down) |> Amounts.grouped() |> zeros()

    assigns
    |> assign(exact: assigns.amount, shown: shown)
    |> figure()
  end

  attr :value, :string, required: true
  attr :unit, :string, default: nil

  @doc """
  A figure already written for the page, such as a grouped whole-token count,
  set like every other figure: the number, then its ticker.
  """
  def written(assigns),
    do: assigns |> assign(exact: assigns.value, shown: assigns.value) |> figure()

  # Only a plain finite decimal is shortened: digits, one optional fraction,
  # one optional leading minus. Decimal's parser would also take NaN, Infinity
  # and exponents, none of which is a price. Exact Q96 prices carry up to 96
  # decimal places, far past Decimal's default 34-digit parse limit, so the
  # parse of an admitted string is unbounded.
  @plain_decimal ~r/\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/

  defp significant(amount, round) do
    if Regex.match?(@plain_decimal, amount) do
      {decimal, ""} = Decimal.parse(amount, max_digits: :infinity)
      decimal |> rounded(round) |> Decimal.to_string(:normal)
    else
      amount
    end
  end

  # In whole-number arithmetic: Decimal's own rounding would first cut an exact
  # Q96 price to its context precision and could round it twice.
  defp rounded(%Decimal{coef: 0}, _round), do: Decimal.new(0)

  defp rounded(%Decimal{sign: sign, coef: coef, exp: exp}, round) do
    cut = max(length(Integer.digits(coef)) - @significant_digits, 0)
    unit = Integer.pow(10, cut)
    kept = div(coef, unit)
    kept = if round == :nearest and 2 * rem(coef, unit) >= unit, do: kept + 1, else: kept
    trimmed(sign, kept, exp + cut)
  end

  defp trimmed(sign, coef, exp) when rem(coef, 10) == 0, do: trimmed(sign, div(coef, 10), exp + 1)
  defp trimmed(sign, coef, exp), do: Decimal.new(sign, coef, exp)

  attr :text, :string, required: true
  attr :tickers, :list, default: [], doc: "the tickers to pick out; blanks are skipped"

  @doc """
  A sentence with its figures set like every other figure: each number bold,
  each named ticker in the ticker colour, as in "0.0196 AAPLc was returned".
  A number inside a word, such as an address, is left alone.
  """
  def marked(assigns) do
    assigns = assign(assigns, :parts, marks(assigns.text, assigns.tickers))

    ~H"""
    <.mark :for={part <- @parts} part={part} />
    """
  end

  @number "(?<![\\w.])\\d(?:[\\d,\\x{2080}-\\x{2089}]|\\.(?=\\d))*(?!\\w)"

  defp marks(text, tickers) do
    pattern = Regex.compile!("(#{@number})(?: (#{names(tickers)}))?|(#{names(tickers)})", "u")

    pattern
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn piece ->
      case Regex.run(pattern, piece) do
        [^piece, value] -> {value, nil}
        [^piece, value, ticker] -> {value, ticker}
        [^piece, "", "", ticker] -> {nil, ticker}
        _text -> piece
      end
    end)
  end

  # Whole-word tickers, or a pattern that never matches when none are named.
  defp names(tickers) do
    case Enum.reject(tickers, &(&1 in [nil, ""])) do
      [] -> "(?!)"
      named -> "\\b(?:#{Enum.map_join(named, "|", &Regex.escape/1)})\\b"
    end
  end

  defp mark(%{part: {nil, _ticker}} = assigns) do
    ~H"""
    <span class="ticker">{elem(@part, 1)}</span>
    """
  end

  defp mark(%{part: {_value, nil}} = assigns) do
    ~H"""
    <span class="figure__value">{elem(@part, 0)}</span>
    """
  end

  defp mark(%{part: {_value, _ticker}} = assigns) do
    ~H"""
    <span class="figure"><span class="figure__value">{elem(@part, 0)}</span>{" "}<span class="figure__unit">{elem(
      @part,
      1
    )}</span></span>
    """
  end

  defp mark(assigns) do
    ~H"""
    {@part}
    """
  end

  # The number and its ticker in their own spans, so a page can set them
  # apart. A shortened number keeps its exact form, with the ticker, for
  # assistive technology and on hover.
  defp figure(%{exact: same, shown: same} = assigns) do
    ~H"""
    <span class="figure"><span class="figure__value">{@shown}</span><.unit unit={@unit} /></span>
    """
  end

  defp figure(assigns) do
    assigns = assign(assigns, :label, Enum.join([assigns.exact, assigns.unit] -- [nil], " "))

    ~H"""
    <span class="figure" aria-hidden="true" title={@label}><span class="figure__value">{@shown}</span><.unit unit={
      @unit
    } /></span><span class="visually-hidden">{@label}</span>
    """
  end

  defp unit(%{unit: nil} = assigns), do: ~H""

  defp unit(assigns) do
    ~H"""
    {" "}<span class="figure__unit">{@unit}</span>
    """
  end

  defp compact(amount) do
    decimal = Decimal.new(amount)

    Enum.find_value(@scales, amount, fn {scale, suffix} ->
      Decimal.gte?(decimal, scale) && mantissa(decimal, scale) <> suffix
    end)
  end

  defp mantissa(decimal, scale) do
    decimal
    |> Decimal.div(scale)
    |> Decimal.round(2, :floor)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end
end
