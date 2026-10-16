defmodule Autolaunch.RewardHistory do
  @moduledoc """
  What one wallet has claimed from a launch splitter, read from the
  splitter's own `Claimed` events. Revstake and Memestock splitters, first
  and second launchpad and Robinhood alike, emit the same event.

  Nothing here writes, signs or caches; every figure is the chain's own answer.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi

  @claimed "Claimed(address,address,uint256)"

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
  defp hex(value), do: "0x" <> Integer.to_string(value, 16)
end
