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

  @doc """
  A read-only price. A price carrying more than four significant digits is
  shortened on screen, truncated rather than rounded up, while the exact figure
  stays readable to assistive technology and on hover. The exact string is
  never altered: an amount that is not a plain decimal is shown as written.
  """
  def price(%{amount: amount} = assigns) when is_nil(amount) or amount == "" do
    ~H"""
    {@fallback}
    """
  end

  def price(assigns) do
    assigns
    |> assign(
      exact: with_unit(assigns.amount, assigns.unit),
      shown: with_unit(significant(assigns.amount), assigns.unit)
    )
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

  defp significant(amount) do
    if Regex.match?(@plain_decimal, amount) do
      {decimal, ""} = Decimal.parse(amount, max_digits: :infinity)
      truncate_significant(decimal)
    else
      amount
    end
  end

  defp truncate_significant(%Decimal{coef: 0}), do: "0"

  defp truncate_significant(%Decimal{coef: coef, exp: exp} = decimal) when is_integer(coef) do
    digits = coef |> Integer.digits() |> length()

    decimal
    |> Decimal.round(@significant_digits - digits - exp, :down)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp figure(%{exact: same, shown: same} = assigns) do
    ~H"""
    {@exact}
    """
  end

  defp figure(assigns) do
    ~H"""
    <span aria-hidden="true" title={@exact}>{@shown}</span>
    <span class="visually-hidden">{@exact}</span>
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
