defmodule Autolaunch.WalletHistory do
  @moduledoc """
  One wallet's own moves in a launched token, read from the chain's logs:
  the transactions that moved the token into or out of the wallet (the
  token's `Transfer` events with the wallet as the indexed receiver or
  sender), and the wallet's stakes in the launch's splitter (`Staked` events
  with the wallet as the indexed staker), the same way `Autolaunch.RewardHistory`
  reads its claims.

  Nothing here writes, signs or caches; every figure is the chain's own answer.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi

  @transfer "Transfer(address,address,uint256)"
  @staked "Staked(address,uint256)"

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
    filter = %{
      address: address,
      fromBlock: hex(from_block),
      toBlock: hex(block.number),
      topics: topics
    }

    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, logs} when is_list(logs) -> {:ok, Enum.reject(logs, & &1["removed"])}
      {:ok, _other} -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp address_topic(address),
    do:
      "0x" <>
        (address |> String.trim_leading("0x") |> String.downcase() |> String.pad_leading(64, "0"))

  defp hex(value), do: "0x" <> Integer.to_string(value, 16)
end
