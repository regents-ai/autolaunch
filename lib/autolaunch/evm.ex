defmodule Autolaunch.Evm do
  @moduledoc false

  @address_pattern ~r/^0x[0-9a-f]{40}$/

  def normalize_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> valid_address()
  end

  def normalize_address(_value), do: nil

  def normalize_required_address(value) do
    case normalize_address(value) do
      "0x" <> _address = normalized -> {:ok, normalized}
      _ -> {:error, :invalid_address}
    end
  end

  def normalize_address_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_address/1)
    |> strict_address_list()
    |> case do
      {:error, _reason} = error -> error
      addresses -> {:ok, addresses}
    end
  end

  def normalize_address_list(_values), do: {:error, :invalid_address}

  def normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_string(_value), do: nil

  defp valid_address(""), do: nil

  defp valid_address(normalized) do
    if Regex.match?(@address_pattern, normalized), do: normalized, else: nil
  end

  defp strict_address_list(addresses) do
    if Enum.any?(addresses, &is_nil/1) do
      {:error, :invalid_address}
    else
      addresses
      |> Enum.uniq()
      |> case do
        [] -> {:error, :invalid_address}
        normalized -> normalized
      end
    end
  end
end
