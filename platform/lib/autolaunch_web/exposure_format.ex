defmodule AutolaunchWeb.ExposureFormat do
  @moduledoc """
  Exposure figures as pages show and read them. Prices and ledgers are WAD
  dollars per stock token; stock and leg amounts are raw units of the stock's
  own decimals; pool quotes are USDC micro-units; times are Unix seconds, shown
  in New York time, the market's own clock. Every conversion is exact, with no
  floating point.
  """

  @wad 1_000_000_000_000_000_000
  @usdc_unit 1_000_000
  @zone "America/New_York"

  @doc "A WAD dollar figure as dollars and cents, rounded to the nearest cent."
  def usd(nil), do: "—"
  def usd(wad) when is_integer(wad), do: cents(div(wad * 100 + div(@wad, 2), @wad))

  @doc "USDC micro-units as dollars and cents, rounded to the nearest cent."
  def usdc(nil), do: "—"

  def usdc(micro) when is_integer(micro),
    do: cents(div(micro * 100 + div(@usdc_unit, 2), @usdc_unit))

  @doc "A raw amount of a token with `decimals` decimals, without trailing zeros."
  def tokens(raw, decimals) when is_integer(raw) and is_integer(decimals) do
    raw
    |> Decimal.new()
    |> Decimal.div(Decimal.new(Integer.pow(10, decimals)))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  @doc "A typed token amount as raw units, or nil when it is not a positive amount that fits."
  def parse_tokens(text, decimals) when is_binary(text) do
    text = text |> String.trim() |> String.replace(",", "")

    with {decimal, ""} <- Decimal.parse(text),
         true <- Decimal.gt?(decimal, 0),
         scaled = Decimal.mult(decimal, Integer.pow(10, decimals)),
         true <- Decimal.integer?(scaled) do
      Decimal.to_integer(scaled)
    else
      _not_an_amount -> nil
    end
  end

  def parse_tokens(_text, _decimals), do: nil

  @doc "`part` of `whole` as a percentage with one decimal, or a dash when there is no whole."
  def percent(_part, 0), do: "—"

  def percent(part, whole) do
    tenths = div(part * 1_000 + div(whole, 2), whole)
    "#{div(tenths, 10)}.#{rem(tenths, 10)}%"
  end

  @doc """
  How many times the stock's move a leg moves in its own window now: the price
  over the leg's ledger, to one decimal, or a dash for an empty ledger.
  """
  def times(_price, 0), do: "—"

  def times(price, ledger) do
    tenths = div(price * 10 + div(ledger, 2), ledger)
    "#{div(tenths, 10)}.#{rem(tenths, 10)}×"
  end

  @doc "A moment as its New York day and time, as in \"Fri 30 Oct, 4:00pm\"."
  def moment(unix) when is_integer(unix) do
    at = unix |> DateTime.from_unix!() |> DateTime.shift_zone!(@zone)
    Calendar.strftime(at, "%a %-d %b, %-I:%M") <> String.downcase(Calendar.strftime(at, "%p"))
  end

  defp cents(cents) do
    "$" <>
      group(div(cents, 100)) <>
      "." <> String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
  end

  defp group(dollars) do
    dollars
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
