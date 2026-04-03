defmodule Autolaunch.CCA.Contract do
  @moduledoc false

  alias Autolaunch.CCA.Abi
  alias Autolaunch.CCA.Rpc

  @tick_limit 2_048

  def snapshot(chain_id, auction_address) do
    with {:ok, block_number} <- Rpc.block_number(chain_id),
         {:ok, checkpoint} <- call_checkpoint(chain_id, auction_address),
         {:ok, floor_price_q96} <- call_uint(chain_id, auction_address, :floor_price),
         {:ok, tick_spacing_q96} <- call_uint(chain_id, auction_address, :tick_spacing),
         {:ok, next_active_tick_price_q96} <-
           call_uint(chain_id, auction_address, :next_active_tick_price),
         {:ok, sum_currency_demand_above_clearing_q96} <-
           call_uint(chain_id, auction_address, :sum_currency_demand_above_clearing_q96),
         {:ok, total_supply} <- call_uint(chain_id, auction_address, :total_supply),
         {:ok, required_currency_raised} <-
           call_uint(chain_id, auction_address, :required_currency_raised),
         {:ok, currency_raised} <- call_uint(chain_id, auction_address, :currency_raised),
         {:ok, total_cleared} <- call_uint(chain_id, auction_address, :total_cleared),
         {:ok, start_block} <- call_uint(chain_id, auction_address, :start_block),
         {:ok, end_block} <- call_uint(chain_id, auction_address, :end_block),
         {:ok, claim_block} <- call_uint(chain_id, auction_address, :claim_block),
         {:ok, max_bid_price_q96} <- call_uint(chain_id, auction_address, :max_bid_price),
         {:ok, is_graduated} <- call_bool(chain_id, auction_address, :is_graduated) do
      {:ok,
       %{
         auction_address: normalize_address(auction_address),
         chain_id: chain_id,
         block_number: block_number,
         checkpoint: checkpoint,
         floor_price_q96: floor_price_q96,
         tick_spacing_q96: tick_spacing_q96,
         next_active_tick_price_q96: next_active_tick_price_q96,
         sum_currency_demand_above_clearing_q96: sum_currency_demand_above_clearing_q96,
         total_supply: total_supply,
         required_currency_raised_wei: required_currency_raised,
         currency_raised_wei: currency_raised,
         total_cleared_units: total_cleared,
         start_block: start_block,
         end_block: end_block,
         claim_block: claim_block,
         max_bid_price_q96: max_bid_price_q96,
         is_graduated: is_graduated
       }}
    end
  end

  def load_ticks(chain_id, auction_address, floor_price_q96) do
    do_load_ticks(chain_id, auction_address, floor_price_q96, %{}, 0)
  end

  def bid(chain_id, auction_address, bid_id) when is_integer(bid_id) and bid_id >= 0 do
    chain_id
    |> Rpc.eth_call(auction_address, Abi.encode_call(:bids, [{:uint256, bid_id}]))
    |> case do
      {:ok, result} -> Abi.decode_bid(result)
      {:error, _} = error -> error
    end
  end

  def checkpoint_history(chain_id, auction_address, from_block, to_block)
      when is_integer(from_block) and is_integer(to_block) and from_block <= to_block do
    chain_id
    |> Rpc.get_logs(%{
      "address" => normalize_address(auction_address),
      "fromBlock" => to_hex_quantity(from_block),
      "toBlock" => to_hex_quantity(to_block),
      "topics" => [Abi.event_topic(:checkpoint_updated)]
    })
    |> case do
      {:ok, logs} ->
        logs
        |> Enum.map(&Abi.decode_checkpoint_updated_log/1)
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, checkpoint_log}, {:ok, acc} -> {:cont, {:ok, [checkpoint_log | acc]}}
          {:error, reason}, _acc -> {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, decoded} ->
            {:ok, Enum.sort_by(decoded, & &1.checkpoint_block_number)}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_load_ticks(_chain_id, _auction_address, _current_price_q96, _acc, count)
       when count >= @tick_limit do
    {:error, :tick_limit_exceeded}
  end

  defp do_load_ticks(chain_id, auction_address, current_price_q96, acc, count) do
    if current_price_q96 == Abi.max_u256() do
      {:ok, acc}
    else
      with {:ok, tick} <- tick(chain_id, auction_address, current_price_q96) do
        next_price = tick.next_price_q96

        updated =
          Map.put(acc, current_price_q96, %{
            price_q96: current_price_q96,
            next_price_q96: next_price,
            currency_demand_q96: tick.currency_demand_q96
          })

        if next_price in [0, Abi.max_u256()] do
          {:ok, updated}
        else
          do_load_ticks(chain_id, auction_address, next_price, updated, count + 1)
        end
      end
    end
  end

  def tick(chain_id, auction_address, price_q96) do
    chain_id
    |> Rpc.eth_call(auction_address, Abi.encode_call(:ticks, [{:uint256, price_q96}]))
    |> case do
      {:ok, result} -> Abi.decode_tick(result)
      {:error, _} = error -> error
    end
  end

  defp call_checkpoint(chain_id, auction_address) do
    chain_id
    |> Rpc.eth_call(auction_address, Abi.encode_call(:checkpoint, []))
    |> case do
      {:ok, result} -> Abi.decode_checkpoint(result)
      {:error, _} = error -> error
    end
  end

  defp call_uint(chain_id, auction_address, selector_name) do
    chain_id
    |> Rpc.eth_call(auction_address, Abi.encode_call(selector_name, []))
    |> case do
      {:ok, result} -> {:ok, Abi.decode_uint256(result)}
      {:error, _} = error -> error
    end
  end

  defp call_bool(chain_id, auction_address, selector_name) do
    chain_id
    |> Rpc.eth_call(auction_address, Abi.encode_call(selector_name, []))
    |> case do
      {:ok, result} -> {:ok, Abi.decode_bool(result)}
      {:error, _} = error -> error
    end
  end

  defp normalize_address(address) when is_binary(address),
    do: String.downcase(String.trim(address))

  defp to_hex_quantity(value) when is_integer(value) and value >= 0 do
    "0x" <> Integer.to_string(value, 16)
  end
end
