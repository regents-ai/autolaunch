defmodule AutolaunchWeb.CoveredCallsFormat do
  @moduledoc """
  Covered-call amounts as pages show and read them. USDC is 6 decimals and a
  stock token's raw units come from its contract (`unit`, 10^8 for Base
  stocks); every conversion is exact, with no floating point.
  """

  @usdc_unit 1_000_000
  # The largest amount a page takes: far beyond any real one, and well inside
  # what a contract call can carry.
  @largest 2 ** 128 - 1

  @doc """
  USDC micro-units as dollars, exactly: two decimals, and more only when the
  amount has them ($250.005), so a figure is never rounded either way.
  """
  def usd(nil), do: "—"

  def usd(micro) when is_integer(micro) do
    fraction =
      micro
      |> rem(@usdc_unit)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")
      |> String.pad_trailing(2, "0")

    "$" <> group(div(micro, @usdc_unit)) <> "." <> fraction
  end

  @doc "A raw stock amount as whole tokens, without trailing zeros."
  def tokens(raw, unit) when is_integer(raw) and is_integer(unit) do
    raw
    |> Decimal.new()
    |> Decimal.div(Decimal.new(unit))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  @doc """
  A typed token amount as raw units, or nil when it is not a positive amount
  that fits. Digits with at most one dot: a comma is never read as either a
  thousands separator or a decimal point, since people write it both ways.
  """
  def parse_tokens(text, unit), do: parse(text, unit)

  @doc "A typed dollar amount as USDC micro-units, read as `parse_tokens/2` reads, with an optional `$`."
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
    decimals = String.length(Integer.to_string(unit)) - 1

    with [_text, whole | fraction] <-
           Regex.run(~r/\A(\d*)(?:\.(\d*))?\z/, text |> String.trim() |> String.trim_leading("$")),
         fraction = Enum.join(fraction),
         true <- whole <> fraction != "",
         fraction = String.trim_trailing(fraction, "0"),
         true <- String.length(fraction) <= decimals,
         raw =
           String.to_integer("0" <> whole) * unit +
             String.to_integer("0" <> String.pad_trailing(fraction, decimals, "0")),
         true <- raw > 0 and raw <= @largest do
      raw
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
