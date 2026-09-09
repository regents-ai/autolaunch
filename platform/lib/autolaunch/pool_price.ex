defmodule Autolaunch.PoolPrice do
  @moduledoc """
  The one conversion from a Uniswap v4 `sqrtPriceX96` to a readable pool price.

  A pool prices `currency1` base units per `currency0` base unit as
  `(sqrtPriceX96 / 2^96)^2`. The pages state the price the other way round when
  the launch token is `currency1`, and always in whole tokens ("currency per
  token"), so the two currency orders and the two decimals pairs are handled
  here once. Whenever the exact value is a finite decimal it is rendered in
  full; otherwise it is truncated (never rounded up) and marked as such.
  """

  @q192 Integer.pow(2, 192)
  @uint160_max Integer.pow(2, 160) - 1
  @truncated_fraction_digits 36

  @type price :: %{value: String.t(), exact?: boolean()}

  @doc """
  Currency per one whole launch token for a pool's `sqrtPriceX96`.

  `token_is_currency0?` says which side of the pool the launch token is on;
  `token_decimals` and `currency_decimals` are the two tokens' own decimals.
  """
  @spec currency_per_token(pos_integer(), boolean(), non_neg_integer(), non_neg_integer()) ::
          {:ok, price()} | {:error, :invalid_sqrt_price}
  def currency_per_token(sqrt_price_x96, token_is_currency0?, token_decimals, currency_decimals)
      when is_integer(sqrt_price_x96) and sqrt_price_x96 in 1..@uint160_max and
             is_boolean(token_is_currency0?) and
             is_integer(token_decimals) and token_decimals in 0..255 and
             is_integer(currency_decimals) and currency_decimals in 0..255 do
    squared = sqrt_price_x96 * sqrt_price_x96
    scale_up = Integer.pow(10, token_decimals)
    scale_down = Integer.pow(10, currency_decimals)

    {numerator, denominator} =
      if token_is_currency0?,
        do: {squared * scale_up, @q192 * scale_down},
        else: {@q192 * scale_up, squared * scale_down}

    {:ok, decimal(numerator, denominator)}
  end

  def currency_per_token(_sqrt_price, _order, _token_decimals, _currency_decimals),
    do: {:error, :invalid_sqrt_price}

  # A reduced fraction is a finite decimal exactly when its denominator has no
  # prime factor other than 2 and 5; then the digits are produced without loss.
  defp decimal(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)
    {numerator, denominator} = {div(numerator, gcd), div(denominator, gcd)}
    twos = factor_count(denominator, 2)
    fives = factor_count(div(denominator, Integer.pow(2, twos)), 5)
    rest = div(denominator, Integer.pow(2, twos) * Integer.pow(5, fives))

    if rest == 1 do
      digits = max(twos, fives)
      scaled = numerator * div(Integer.pow(10, digits), denominator)
      %{value: plain(scaled, digits), exact?: true}
    else
      scaled = div(numerator * Integer.pow(10, @truncated_fraction_digits), denominator)
      %{value: plain(scaled, @truncated_fraction_digits) <> "…", exact?: false}
    end
  end

  defp factor_count(value, prime, count \\ 0) do
    if rem(value, prime) == 0,
      do: factor_count(div(value, prime), prime, count + 1),
      else: count
  end

  defp plain(raw, 0), do: Integer.to_string(raw)

  defp plain(raw, decimals) do
    digits = raw |> Integer.to_string() |> String.pad_leading(decimals + 1, "0")
    {whole, fraction} = String.split_at(digits, byte_size(digits) - decimals)
    fraction = String.trim_trailing(fraction, "0")
    if fraction == "", do: whole, else: whole <> "." <> fraction
  end
end
