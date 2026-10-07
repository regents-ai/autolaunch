defmodule Autolaunch.RewardHistory do
  @moduledoc """
  A launch splitter's own record of its rewards, read from its events: every
  arrival it recognized with the stakers' part of it, and what one wallet has
  claimed. Revstake and Memestake splitters, first and second launchpad and
  Robinhood alike, emit the same `Claimed` event; their `RevenueRecognized`
  events differ only in where the stakers' part sits in the data.

  Nothing here writes, signs or caches; every figure is the chain's own answer.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi

  @recognized %{
    revstake:
      "RevenueRecognized(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)",
    memestake: "RevenueRecognized(address,address,bytes32,uint256,uint256,uint256)"
  }
  # The stakers' part in each event's data: [gross, skim, net, stakerShare,
  # treasuryShare] for Revstake, [gross, protocolShare, stakerShare] for Memestake.
  @staker_word %{revstake: 3, memestake: 2}
  @claimed "Claimed(address,address,uint256)"

  @doc """
  Every arrival `splitter` recognized from `from_block` to `block`, oldest
  first: the asset, the address that sent it, the stakers' part in atomic
  units, and the block and transaction it arrived in.
  """
  @spec recognized(:revstake | :memestake, String.t(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def recognized(kind, splitter, from_block, block, opts) do
    topic = LabAbi.topic(Map.fetch!(@recognized, kind))

    with {:ok, logs} <- logs(splitter, from_block, block, [topic], opts) do
      {:ok, Enum.map(logs, &recognition(&1, Map.fetch!(@staker_word, kind)))}
    end
  end

  @doc """
  What `account` has claimed from `splitter` from `from_block` to `block`, in
  atomic units per asset, keyed by the asset's lowercase address.
  """
  @spec claimed(String.t(), String.t(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, atom()}
  def claimed(splitter, account, from_block, block, opts) do
    topics = [LabAbi.topic(@claimed), address_topic(account)]

    with {:ok, logs} <- logs(splitter, from_block, block, topics, opts) do
      {:ok,
       Enum.reduce(logs, %{}, fn log, sums ->
         [amount] = data_words(log)
         Map.update(sums, address_at(log, 2), amount, &(&1 + amount))
       end)}
    end
  end

  defp recognition(log, staker_word) do
    %{
      asset: address_at(log, 1),
      source: address_at(log, 2),
      amount: log |> data_words() |> Enum.at(staker_word),
      block: quantity(log["blockNumber"]),
      transaction_hash: String.downcase(log["transactionHash"])
    }
  end

  defp logs(address, from_block, block, topics, opts) do
    Rpc.request(
      "eth_getLogs",
      [
        %{
          address: address,
          fromBlock: hex(from_block),
          toBlock: hex(block.number),
          topics: topics
        }
      ],
      opts
    )
  end

  defp address_at(%{"topics" => topics}, index) do
    {:ok, address} = topics |> Enum.at(index) |> word() |> Abi.word_address()
    String.downcase(address)
  end

  defp address_topic(address),
    do:
      "0x" <>
        (address |> String.trim_leading("0x") |> String.downcase() |> String.pad_leading(64, "0"))

  defp data_words(%{"data" => "0x" <> hex}),
    do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
  defp quantity("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex(value), do: "0x" <> Integer.to_string(value, 16)
end
