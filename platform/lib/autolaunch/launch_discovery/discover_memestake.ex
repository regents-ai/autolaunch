defmodule Autolaunch.LaunchDiscovery.DiscoverMemestake do
  @moduledoc """
  Records every Base Memestake launch created since the last run, with the
  transaction that created it.

  The launchpad numbers its launches, and each record names its launcher and
  auction. The auction opens exactly `START_LEAD_BLOCKS` (300, in
  `StocksPreset.sol`) after the block the launch was created in, so the
  `StockLaunchCreated` log, and with it the transaction, is read from that one
  block.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @start_lead_blocks 300

  def run(_input, _context) do
    Launchpads.configured()
    |> Enum.filter(&(&1.launchpad == :base_memestake))
    |> Enum.reduce_while(:ok, fn pad, :ok ->
      case discover(pad) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp discover(pad) do
    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, last} <- Launchpads.last_launch_id(pad, block),
         {:ok, known} <- known(pad),
         do: record_new(pad, (known + 1)..last//1, block)
  end

  defp record_new(pad, launch_ids, block) do
    Enum.reduce_while(launch_ids, :ok, fn launch_id, :ok ->
      case record(pad, launch_id, block) do
        {:ok, _discovery} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp known(pad) do
    case Autolaunch.latest_launch_discovery(pad.chain_id, pad.contract, actor: %System{}) do
      {:ok, nil} -> {:ok, 0}
      {:ok, discovery} -> {:ok, discovery.launch_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(pad, launch_id, block) do
    with {:ok, [launcher, _token, _stock, auction, _splitter, start_block | _rest]} <-
           Rpc.call_words(
             pad.contract,
             LabAbi.encode(pad.abi, "launches(uint256)", [launch_id]),
             block,
             StocksLabAbi.launch_record_words(),
             pad.opts
           ),
         {:ok, launcher} <- address(launcher),
         {:ok, auction} <- address(auction),
         {:ok, hash} <- creation_transaction(pad, launch_id, start_block - @start_lead_blocks) do
      Autolaunch.record_launch_discovery(
        %{
          launchpad: pad.launchpad,
          chain_id: pad.chain_id,
          contract: pad.contract,
          launch_id: launch_id,
          launcher: launcher,
          auction: auction,
          transaction_hash: hash
        },
        actor: %System{}
      )
    end
  end

  defp creation_transaction(pad, launch_id, created_block) do
    filter = %{
      address: pad.contract,
      fromBlock: quantity(created_block),
      toBlock: quantity(created_block),
      topics: [Abi.topic0(StocksLabAbi.launch_created_signature()), word(launch_id)]
    }

    case Rpc.request("eth_getLogs", [filter], pad.opts) do
      {:ok, [%{"transactionHash" => hash}]} when is_binary(hash) ->
        {:ok, String.downcase(hash)}

      {:ok, _logs} ->
        {:error, {:launch_log_not_found, launch_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp address(word) do
    case Abi.word_address(word) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_chain_response}
    end
  end

  defp quantity(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))

  defp word(number),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(number, 16)), 64, "0")
end
