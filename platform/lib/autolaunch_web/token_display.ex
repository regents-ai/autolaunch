defmodule AutolaunchWeb.TokenDisplay do
  @moduledoc false
  use Phoenix.Component

  attr :amount, :string, default: nil
  attr :unit, :string, required: true

  @doc """
  A read-only token amount, shown the one way every Regent page shows an amount
  (`RegentFormat.amount/1`), its exact amount readable to assistive technology
  and on hover. Never an input.
  """
  def amount(%{amount: nil} = assigns) do
    ~H"""
    —
    """
  end

  def amount(assigns),
    do: assigns |> assign(exact: assigns.amount, shown: short(assigns.amount)) |> figure()

  attr :amount, :string, default: nil
  attr :unit, :string, default: nil
  attr :fallback, :string, default: "No price yet"

  @doc """
  A read-only price, shown as `amount/1` shows an amount, or `fallback` while
  there is none. An exact price can run to 96 decimal places, so the shown
  figure is also the one given to assistive technology.
  """
  def price(%{amount: amount} = assigns) when is_nil(amount) or amount == "" do
    ~H"""
    {@fallback}
    """
  end

  def price(assigns) do
    shown = short(assigns.amount)
    assigns |> assign(exact: shown, shown: shown) |> figure()
  end

  attr :amount, :string, required: true
  attr :unit, :string, default: nil

  @doc "A read-only token amount read from the chain, shown as `amount/1` shows one."
  def tokens(assigns),
    do: assigns |> assign(exact: assigns.amount, shown: short(assigns.amount)) |> figure()

  attr :value, :string, required: true
  attr :unit, :string, default: nil

  @doc """
  A figure already written for the page, such as an amount a person typed,
  set like every other figure: the number, then its ticker.
  """
  def written(assigns),
    do: assigns |> assign(exact: assigns.value, shown: assigns.value) |> figure()

  # Only a plain finite decimal is a figure to shorten: digits, one optional
  # fraction, one optional leading minus. Decimal's parser would also take NaN,
  # Infinity and exponents. Exact Q96 prices carry up to 96 decimal places, far
  # past Decimal's default 34-digit parse limit, so the parse is unbounded.
  @plain_decimal ~r/\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/

  @doc """
  An amount as text, as `amount/1` shows it: a plain decimal string or a
  Decimal through `RegentFormat.amount/1`; any other text as written.
  """
  def short(%Decimal{} = amount), do: RegentFormat.amount(amount)

  def short(amount) when is_binary(amount) do
    if Regex.match?(@plain_decimal, amount) do
      {decimal, ""} = Decimal.parse(amount, max_digits: :infinity)
      RegentFormat.amount(decimal)
    else
      amount
    end
  end

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

  @number "(?<![\\w.])\\d(?:[\\d,]|\\.(?=\\d))*(?!\\w)"

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
    <span class="figure"><span class="figure__value" data-count>{@shown}</span><.unit unit={@unit} /></span>
    """
  end

  defp figure(assigns) do
    assigns = assign(assigns, :label, Enum.join([assigns.exact, assigns.unit] -- [nil], " "))

    ~H"""
    <span class="figure" aria-hidden="true" title={@label}><span class="figure__value" data-count>{@shown}</span><.unit unit={
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
end
