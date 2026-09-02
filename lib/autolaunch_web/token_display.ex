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
