defmodule Autolaunch.WalletHistory do
  @moduledoc """
  One wallet's own moves in a launched token, read from the chain's logs:
  the transactions that moved the token into or out of the wallet (the
  token's `Transfer` events with the wallet as the indexed receiver or
  sender), the wallet's stakes in the launch's splitter (`Staked` events
  with the wallet as the indexed staker) and what it has claimed from the
  splitter (`Claimed` events). Revstake and Memestock splitters, first and
  second launchpad and Robinhood alike, emit the same events.

  Nothing here writes, signs or caches; every figure is the chain's own answer.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi

  @transfer "Transfer(address,address,uint256)"
  @staked "Staked(address,uint256)"
  @claimed "Claimed(address,address,uint256)"

  @doc """
  The transactions from `from_block` to `block` in which `token` moved into
  `wallet` (`received`) and out of it (`sent`), by lowercase hash.
  """
  @spec transfers(String.t(), String.t(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, %{received: MapSet.t(), sent: MapSet.t()}} | {:error, atom()}
  def transfers(token, wallet, from_block, block, opts) do
    topic = LabAbi.topic(@transfer)

    with {:ok, received} <-
           logs(token, from_block, block, [topic, nil, address_topic(wallet)], opts),
         {:ok, sent} <- logs(token, from_block, block, [topic, address_topic(wallet)], opts) do
      {:ok, %{received: hashes(received), sent: hashes(sent)}}
    end
  end

  @doc """
  Each stake `wallet` made in `splitter` from `from_block` to `block`, in
  chain order: the block it landed in and the amount in atomic units.
  """
  @spec stakes(String.t(), String.t(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, [%{block_number: non_neg_integer(), amount: non_neg_integer()}]}
          | {:error, atom()}
  def stakes(splitter, wallet, from_block, block, opts) do
    topics = [LabAbi.topic(@staked), address_topic(wallet)]

    with {:ok, logs} <- logs(splitter, from_block, block, topics, opts),
         do: decoded(logs)
  end

  @doc """
  What `account` has claimed from `splitter` from `from_block` to `block`, in
  atomic units per asset, keyed by the asset's lowercase address.
  """
  @spec claimed(String.t(), String.t(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, atom()}
  def claimed(splitter, account, from_block, block, opts) do
    topics = [LabAbi.topic(@claimed), address_topic(account)]

    with {:ok, logs} <- Rpc.logs(splitter, topics, from_block, block.number, opts) do
      {:ok,
       Enum.reduce(logs, %{}, fn %{"topics" => topics, "data" => "0x" <> data}, sums ->
         [amount] = for <<word::binary-size(64) <- data>>, do: String.to_integer(word, 16)
         "0x" <> asset_word = Enum.at(topics, 2)
         {:ok, asset} = asset_word |> String.to_integer(16) |> Abi.word_address()
         Map.update(sums, String.downcase(asset), amount, &(&1 + amount))
       end)}
    end
  end

  defp decoded(logs) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, found} ->
      case stake(log) do
        {:ok, stake} -> {:cont, {:ok, [stake | found]}}
        :error -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  defp stake(%{"removed" => false, "blockNumber" => "0x" <> number, "data" => "0x" <> data}) do
    with {number, ""} <- Integer.parse(number, 16),
         <<amount::binary-size(64)>> <- data,
         {amount, ""} <- Integer.parse(amount, 16) do
      {:ok, %{block_number: number, amount: amount}}
    else
      _invalid -> :error
    end
  end

  defp stake(_log), do: :error

  defp hashes(logs),
    do: MapSet.new(logs, &String.downcase(&1["transactionHash"]))

  defp logs(address, from_block, block, topics, opts) do
    with {:ok, logs} <- Rpc.logs(address, topics, from_block, block.number, opts),
         do: {:ok, Enum.reject(logs, & &1["removed"])}
  end

  defp address_topic(address),
    do:
      "0x" <>
        (address |> String.trim_leading("0x") |> String.downcase() |> String.pad_leading(64, "0"))
end
