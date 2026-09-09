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
             is_integer(decimals) and decimals in 0..255,
      do: {:ok, plain_decimal(raw, decimals)}

  def format_units(_, _), do: {:error, :invalid_amount}

  defp plain_decimal(raw, 0), do: Integer.to_string(raw)

  defp plain_decimal(raw, decimals) do
    digits = raw |> Integer.to_string() |> String.pad_leading(decimals + 1, "0")
    {whole, fraction} = String.split_at(digits, byte_size(digits) - decimals)
    fraction = String.trim_trailing(fraction, "0")
    if fraction == "", do: whole, else: whole <> "." <> fraction
  end

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

  @doc """
  The exact decimal STOCK-per-NEW a Q96 CCA price names, with no rounding.

  `q96 / 2^96` is currency base units per NEW base unit; multiplying by
  `10^new_decimals / 10^stock_decimals` gives whole tokens. `1 / 2^96` is
  `5^96 / 10^96`, so the whole value is a finite decimal.
  """
  def format_cca_price(q96, stock_decimals, new_decimals)
      when is_integer(q96) and q96 in 0..@uint256_max and
             is_integer(stock_decimals) and stock_decimals in 0..255 and
             is_integer(new_decimals) and new_decimals in 0..255 do
    plain_decimal(q96 * Integer.pow(5, 96) * Integer.pow(10, new_decimals), 96 + stock_decimals)
  end

  @doc """
  A plain decimal shortened for reading: at most `significant` significant digits,
  truncated (never rounded up) and marked with an ellipsis when digits were cut,
  so a shown price is never higher than the exact one it stands for.
  """
  def compact_decimal(value, significant \\ 12)
      when is_binary(value) and is_integer(significant) and significant > 0 do
    case String.split(value, ".", parts: 2) do
      [_whole] ->
        value

      [whole, fraction] ->
        leading_zeros = byte_size(fraction) - byte_size(String.trim_leading(fraction, "0"))
        whole_digits = if whole == "0", do: 0, else: byte_size(whole)

        keep =
          max(significant - whole_digits, 0) + if(whole_digits == 0, do: leading_zeros, else: 0)

        if byte_size(fraction) <= keep,
          do: value,
          else: whole <> "." <> String.slice(fraction, 0, keep) <> "…"
    end
  end

  defp decimal_ratio(value) when is_binary(value) and byte_size(value) <= @max_input_bytes do
    if Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)?\z/, value) do
      case String.split(value, ".", parts: 2) do
        [whole] ->
          {:ok, String.to_integer(whole), 1}

        [whole, fraction] ->
          {:ok, String.to_integer(whole <> fraction), Integer.pow(10, byte_size(fraction))}
      end
    else
      {:error, :invalid_decimal}
    end
  end

  defp decimal_ratio(_), do: {:error, :invalid_decimal}
end
