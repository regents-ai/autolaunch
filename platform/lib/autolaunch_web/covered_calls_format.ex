defmodule AutolaunchWeb.CoveredCallsFormat do
  @moduledoc """
  Covered-call amounts as pages show and read them. USDC is 6 decimals and a
  stock token's raw units come from its contract (`unit`, 10^8 for Base
  stocks); every conversion is exact, with no floating point.
  """

  @usdc_unit 1_000_000

  @doc "USDC micro-units as dollars and cents, rounded up to the cent when a fraction remains."
  def usd(nil), do: "—"

  def usd(micro) when is_integer(micro) do
    cents = div(micro + 9_999, 10_000)
    dollars = div(cents, 100)
    "$" <> group(dollars) <> "." <> String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
  end

  @doc "A raw stock amount as whole tokens, without trailing zeros."
  def tokens(raw, unit) when is_integer(raw) and is_integer(unit) do
    raw
    |> Decimal.new()
    |> Decimal.div(Decimal.new(unit))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  @doc "A typed token amount as raw units, or nil when it is not a positive amount that fits."
  def parse_tokens(text, unit), do: parse(text, unit)

  @doc "A typed dollar amount as USDC micro-units, or nil when it is not a positive amount that fits."
  def parse_usd(text), do: parse(text, @usdc_unit)

  @doc "A raw amount at `per_token` USDC per whole token, in micro-USDC, rounded up as the contract does."
  def total(raw, per_token, unit),
    do: Autolaunch.CoveredCalls.Terms.usdc_for(raw, per_token, unit)

  @doc "A weekly expiry as its day and time in UTC, the time the contract keeps."
  def expiry(unix) when is_integer(unix),
    do: unix |> DateTime.from_unix!() |> Calendar.strftime("%a %-d %b, %H:%M UTC")

  @doc "The 24-hour window after an expiry, as the time it closes."
  def window_closes(unix) when is_integer(unix),
    do: expiry(unix + Autolaunch.CoveredCalls.Terms.exercise_window())

  defp parse(text, unit) when is_binary(text) do
    text = text |> String.trim() |> String.replace([",", "$"], "")

    with {decimal, ""} <- Decimal.parse(text),
         true <- Decimal.gt?(decimal, 0),
         scaled = Decimal.mult(decimal, unit),
         true <- Decimal.integer?(scaled) do
      Decimal.to_integer(scaled)
    else
      _not_an_amount -> nil
    end
  end

  defp parse(_text, _unit), do: nil

  defp group(dollars) do
    dollars
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
