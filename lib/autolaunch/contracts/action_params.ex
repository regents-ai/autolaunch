defmodule Autolaunch.Contracts.ActionParams do
  @moduledoc false

  alias Autolaunch.Evm

  @zero_address "0x0000000000000000000000000000000000000000"

  def prepare_tx(chain_id, to, data, resource, action, params \\ %{}) do
    if blank?(to) or blank?(data) do
      {:error, :unsupported_action}
    else
      {:ok,
       %{
         resource: resource,
         action: action,
         chain_id: chain_id,
         target: to,
         calldata: data,
         tx_request: %{chain_id: chain_id, to: to, value: "0x0", data: data},
         params: params,
         submission_mode: "prepare_only"
       }}
    end
  end

  def address_param(attrs, key) do
    Evm.normalize_required_address(Map.get(attrs, key))
  end

  def string_param(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if byte_size(trimmed) > 0 do
          {:ok, trimmed}
        else
          {:error, :invalid_string}
        end

      _ ->
        {:error, :invalid_string}
    end
  end

  def uint_param(attrs, key) do
    value = Map.get(attrs, key)

    cond do
      is_integer(value) and value >= 0 ->
        {:ok, value}

      is_binary(value) and value != "" ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed >= 0 -> {:ok, parsed}
          _ -> {:error, :invalid_uint}
        end

      true ->
        {:error, :invalid_uint}
    end
  end

  def boolean_param(attrs, key) do
    value = Map.get(attrs, key)

    case value do
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      1 -> {:ok, true}
      0 -> {:ok, false}
      _ -> {:error, :invalid_boolean}
    end
  end

  def blank?(value), do: value in [nil, "", @zero_address]
end
