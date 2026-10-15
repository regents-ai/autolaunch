defmodule Autolaunch.BidSlippage do
  @moduledoc "Exact minimum stock amounts for stablecoin-funded auction bids."

  @doc "The initial percentage, editable before a bid is signed."
  def default, do: "5"

  @doc "Accepts 0–99.99 percent with at most two decimal places, in basis points."
  def parse(value) when is_binary(value) and byte_size(value) <= 5 do
    if Regex.match?(~r/\A\d{1,2}(?:\.\d{1,2})?\z/, value) do
      [whole, fraction] = String.split(value <> ".", ".") |> Enum.take(2)

      {:ok,
       String.to_integer(whole) * 100 + String.to_integer(String.pad_trailing(fraction, 2, "0"))}
    else
      {:error, :invalid_slippage}
    end
  end

  def parse(_value), do: {:error, :invalid_slippage}

  @doc "Rounds the minimum up so atomic-unit rounding never weakens the chosen limit."
  def minimum(quote, bps) when is_integer(quote) and quote > 0 and bps in 0..9_999,
    do: quote - div(quote * bps, 10_000)

  @doc "The exact percentage for the review."
  def percent(bps),
    do:
      bps
      |> Decimal.new()
      |> Decimal.div(100)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)
end
