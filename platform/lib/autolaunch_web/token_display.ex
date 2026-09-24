defmodule AutolaunchWeb.TokenDisplay do
  @moduledoc false
  use Phoenix.Component

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
    |> assign(
      exact: "#{assigns.amount} #{assigns.unit}",
      shown: "#{compact(assigns.amount)} #{assigns.unit}"
    )
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
    short = assigns.amount |> significant(assigns.round) |> with_unit(assigns.unit)

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
    exact = with_unit(assigns.amount, assigns.unit)

    assigns
    |> assign(exact: exact, shown: zeros(exact))
    |> figure()
  end

  defp with_unit(amount, nil), do: amount
  defp with_unit(amount, unit), do: "#{amount} #{unit}"

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

  defp figure(%{exact: same, shown: same} = assigns) do
    ~H"""
    {@exact}
    """
  end

  defp figure(assigns) do
    ~H"""
    <span aria-hidden="true" title={@exact}>{@shown}</span><span class="visually-hidden">{@exact}</span>
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
