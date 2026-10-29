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
  USDC micro-units as dollars, the one Regents way (`RegentFormat.token_amount/2`):
  two decimals from $1 up, three significant digits below, digits cut and
  never rounded up.
  """
  def usd(nil), do: "—"
  def usd(micro) when is_integer(micro), do: "$" <> RegentFormat.token_amount(micro, 6)

  @doc """
  USDC a person pays, rounded up to the cent before it is shown, so a review
  never shows less than the wallet will be asked for.
  """
  def usd_due(micro) when is_integer(micro), do: usd(div(micro + 9_999, 10_000) * 10_000)

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
  def parse_tokens(text, unit) when is_binary(text), do: parse(String.trim(text), unit)
  def parse_tokens(_text, _unit), do: nil

  @doc """
  A typed dollar price as USDC micro-units, read as `parse_tokens/2` reads,
  after one optional `$`, to the cent: a price is shown to the cent, so a
  typed one never carries more than the page can show.
  """
  def parse_usd(text) when is_binary(text) do
    with cents when is_integer(cents) <-
           text |> String.trim() |> String.replace_prefix("$", "") |> parse(100),
         micro = cents * div(@usdc_unit, 100),
         true <- micro <= @largest do
      micro
    else
      _not_a_price -> nil
    end
  end

  def parse_usd(_text), do: nil

  @doc "A raw amount at `per_token` USDC per whole token, in micro-USDC, rounded up as the contract does."
  def total(raw, per_token, unit),
    do: Autolaunch.CoveredCalls.Terms.usdc_for(raw, per_token, unit)

  @doc "A weekly expiry as its day and time in UTC, the time the contract keeps."
  def expiry(unix) when is_integer(unix),
    do: unix |> DateTime.from_unix!() |> Calendar.strftime("%a %-d %b, %H:%M UTC")

  @doc "The 24-hour window after an expiry, as the time it closes."
  def window_closes(unix) when is_integer(unix),
    do: expiry(unix + Autolaunch.CoveredCalls.Terms.exercise_window())

  defp parse(text, unit) do
    decimals = String.length(Integer.to_string(unit)) - 1

    with [_text, whole | fraction] <- Regex.run(~r/\A(\d*)(?:\.(\d*))?\z/, text),
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
end
