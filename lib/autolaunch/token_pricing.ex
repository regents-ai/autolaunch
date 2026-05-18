defmodule Autolaunch.TokenPricing do
  @moduledoc false

  import Bitwise

  alias Autolaunch.CCA.Rpc
  alias Autolaunch.InfrastructureConfig

  @pools_slot 6
  @pool_slot_selector "0x1e2eaeaf"
  @q192 Decimal.new("6277101735386680763835789423207666416102355444464034512896")
  @same_decimals_delta Decimal.new("1")

  def current_token_price_quote(chain_id, pool_id, token_address) do
    with {:ok, pool_manager} <- pool_manager_address(chain_id),
         {:ok, quote_token_address} <- quote_token_address(chain_id),
         {:ok, normalized_pool_id} <- normalize_bytes32(pool_id),
         {:ok, normalized_token} <- normalize_address(token_address),
         {:ok, normalized_quote_token} <- normalize_address(quote_token_address),
         {:ok, sqrt_price_x96} <- load_sqrt_price_x96(chain_id, pool_manager, normalized_pool_id),
         true <- sqrt_price_x96 > 0 do
      {:ok,
       sqrt_price_x96
       |> Decimal.new()
       |> Decimal.mult(Decimal.new(sqrt_price_x96))
       |> price_from_ratio(normalized_token, normalized_quote_token)
       |> Decimal.normalize()
       |> Decimal.to_string(:normal)}
    else
      false -> {:error, :invalid_price}
      {:error, _} = error -> error
      _ -> {:error, :price_unavailable}
    end
  end

  defp price_from_ratio(ratio_numerator, token_address, quote_token_address) do
    raw_ratio = Decimal.div(ratio_numerator, @q192)

    if token_address < quote_token_address do
      Decimal.mult(raw_ratio, @same_decimals_delta)
    else
      Decimal.div(@same_decimals_delta, raw_ratio)
    end
  end

  defp load_sqrt_price_x96(chain_id, pool_manager, pool_id) do
    state_slot = KeccakEx.hash_256(pool_id <> encode_uint256(@pools_slot))

    chain_id
    |> Rpc.eth_call(pool_manager, @pool_slot_selector <> Base.encode16(state_slot, case: :lower))
    |> case do
      {:ok, <<"0x", hex::binary>>} when byte_size(hex) == 64 ->
        <<slot0::unsigned-big-integer-size(256)>> = Base.decode16!(hex, case: :mixed)
        {:ok, band(slot0, (1 <<< 160) - 1)}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_rpc_response}
    end
  end

  defp pool_manager_address(chain_id) do
    case InfrastructureConfig.launch_chain_id() do
      {:ok, ^chain_id} ->
        normalize_address(InfrastructureConfig.launch_value(:pool_manager_address))

      _ ->
        {:error, :missing_pool_manager}
    end
  end

  defp quote_token_address(chain_id) do
    case InfrastructureConfig.launch_chain_id() do
      {:ok, ^chain_id} ->
        normalize_address(InfrastructureConfig.launch_value(:auction_quote_token_address))

      _ ->
        {:error, :missing_quote_token}
    end
  end

  defp normalize_address("0x" <> address = original) when byte_size(address) == 40 do
    {:ok, String.downcase(original)}
  end

  defp normalize_address(_address), do: {:error, :invalid_address}

  defp normalize_bytes32("0x" <> value) when byte_size(value) == 64 do
    {:ok, Base.decode16!(String.upcase(value), case: :mixed)}
  rescue
    _ -> {:error, :invalid_bytes32}
  end

  defp normalize_bytes32(_value), do: {:error, :invalid_bytes32}

  defp encode_uint256(value) when is_integer(value) and value >= 0 do
    <<value::unsigned-big-integer-size(256)>>
  end
end
