defmodule Autolaunch.Stocks.Amounts do
  @moduledoc """
  Exact Stocks unit conversion, independent of asset admission and bid eligibility.

  Decimal inputs are plain nonnegative decimal strings (no exponents, whitespace
  or floats). CCA prices are currency base units per NEW base unit in Q96, as in
  the pinned CCA PriceLib. This is not a pool sqrt-price or tick encoder.
  """
  @uint256_max Integer.pow(2, 256) - 1
  @q96 Integer.pow(2, 96)
  @max_input_bytes 512

  def parse_units(value, decimals) when is_integer(decimals) and decimals in 0..255 do
    with {:ok, numerator, scale} <- decimal_ratio(value),
         scaled = numerator * Integer.pow(10, decimals),
         true <- rem(scaled, scale) == 0,
         raw = div(scaled, scale),
         true <- raw <= @uint256_max do
      {:ok, raw}
    else
      false -> {:error, :amount_not_representable}
      error -> error
    end
  end

  def parse_units(_, _), do: {:error, :invalid_decimals}

  def format_units(raw, decimals)
      when is_integer(raw) and raw in 0..@uint256_max and
             is_integer(decimals) and decimals in 0..255 do
    if decimals == 0 do
      {:ok, Integer.to_string(raw)}
    else
      digits = raw |> Integer.to_string() |> String.pad_leading(decimals + 1, "0")
      {whole, fraction} = String.split_at(digits, byte_size(digits) - decimals)
      fraction = String.trim_trailing(fraction, "0")
      {:ok, if(fraction == "", do: whole, else: whole <> "." <> fraction)}
    end
  end

  def format_units(_, _), do: {:error, :invalid_amount}

  @doc "Returns a downward Q96 candidate and exact rounding evidence; not an executable bid."
  def cca_price(value, stock_decimals, new_decimals)
      when is_integer(stock_decimals) and stock_decimals in 0..255 and
             is_integer(new_decimals) and new_decimals in 0..255 do
    with {:ok, numerator, denominator} <- decimal_ratio(value),
         scaled = numerator * Integer.pow(10, stock_decimals) * @q96,
         divisor = denominator * Integer.pow(10, new_decimals),
         candidate = div(scaled, divisor),
         true <- candidate in 1..@uint256_max do
      {:ok,
       %{
         entered_stock_per_new: value,
         candidate_price_q96: candidate,
         rounding_remainder: rem(scaled, divisor),
         rounding_denominator: divisor,
         adjustment_required: rem(scaled, divisor) != 0
       }}
    else
      false -> {:error, :price_out_of_range}
      error -> error
    end
  end

  def cca_price(_, _, _), do: {:error, :invalid_decimals}

  defp decimal_ratio(value) when is_binary(value) and byte_size(value) <= @max_input_bytes do
    if Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)?\z/, value) do
      case String.split(value, ".", parts: 2) do
        [whole] -> {:ok, String.to_integer(whole), 1}
        [whole, fraction] ->
          {:ok, String.to_integer(whole <> fraction), Integer.pow(10, byte_size(fraction))}
      end
    else
      {:error, :invalid_decimal}
    end
  end

  defp decimal_ratio(_), do: {:error, :invalid_decimal}
end
