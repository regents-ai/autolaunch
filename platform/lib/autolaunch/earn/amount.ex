defmodule Autolaunch.Earn.Amount do
  @moduledoc """
  An amount as a person types it, and back: `entry/2` reads the text into one
  of three states, kept apart from whether the step would go through
  (`Autolaunch.Earn.States.blocked/1`):

    * `:empty` — nothing typed yet
    * `{:invalid, reason}` — text that is not an amount: `:not_a_number`,
      `:too_precise` (more decimals than the token has), `:zero` or `:too_large`
    * `{:valid, units}` — a whole number of the token's smallest units, above zero

  `text/2` writes units the way `entry/2` reads them, digits and a dot only,
  so a figure the page fills in (Max) reads back as exactly what it was.
  """

  # The most a step carries: far beyond any real amount, inside the pool's uint256.
  @most 2 ** 128 - 1

  @type entry :: :empty | {:invalid, reason()} | {:valid, pos_integer()}
  @type reason :: :not_a_number | :too_precise | :zero | :too_large

  @doc "The state of `text` as an amount of a token with `decimals` decimals."
  @spec entry(String.t() | nil, non_neg_integer()) :: entry()
  def entry(text, decimals) when is_binary(text) or is_nil(text) do
    case String.trim(text || "") do
      "" -> :empty
      typed -> typed |> split() |> units(decimals)
    end
  end

  # Digits with at most one dot, and a digit on at least one side of it.
  defp split(typed) do
    case Regex.run(~r/\A(\d*)(?:\.(\d*))?\z/, typed) do
      [_all, whole] when whole != "" -> {:ok, whole, ""}
      [_all, whole, fraction] when whole != "" or fraction != "" -> {:ok, whole, fraction}
      _not_digits -> {:invalid, :not_a_number}
    end
  end

  defp units({:invalid, reason}, _decimals), do: {:invalid, reason}

  defp units({:ok, _whole, fraction}, decimals) when byte_size(fraction) > decimals,
    do: {:invalid, :too_precise}

  defp units({:ok, whole, fraction}, decimals) do
    digits = (whole <> String.pad_trailing(fraction, decimals, "0")) |> String.trim_leading("0")

    case digits do
      "" -> {:invalid, :zero}
      digits -> bounded(String.to_integer(digits))
    end
  end

  defp bounded(units) when units > @most, do: {:invalid, :too_large}
  defp bounded(units) when units <= @most, do: {:valid, units}

  @doc "`units` of a token with `decimals` decimals as text `entry/2` reads back: no separators, no trailing zeros."
  @spec text(non_neg_integer(), non_neg_integer()) :: String.t()
  def text(units, 0) when is_integer(units) and units >= 0, do: Integer.to_string(units)

  def text(units, decimals) when is_integer(units) and units >= 0 and decimals > 0 do
    digits = units |> Integer.to_string() |> String.pad_leading(decimals + 1, "0")
    {whole, fraction} = String.split_at(digits, -decimals)

    case String.trim_trailing(fraction, "0") do
      "" -> whole
      fraction -> whole <> "." <> fraction
    end
  end
end
