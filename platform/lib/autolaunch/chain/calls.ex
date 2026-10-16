defmodule Autolaunch.Chain.Calls do
  @moduledoc """
  What a review the wallet sent as one atomic batch (EIP-5792
  `wallet_sendCalls`) did, read at the latest block of the review's chain from
  the transaction the wallet's own status report named.

  A batch is never one of the review's steps on its own: an account that
  batches itself (EIP-7702) sends it to its own address, and a smart account
  (ERC-4337) has a bundler send it to the entry point. So instead of the step's
  target and calldata, the transaction must carry every step's exact target and
  calldata, in the review's order, on the review's chain. It is the review's
  only when it is sent by the review's signer, or names the signer as the smart
  account that ran it. Anything else is no answer about the review
  (`{:error, :not_this_step}`).

  A smart account's transaction succeeds even when the account's own calls
  fail, so its outcome is the entry point's record of the signer's operation.
  """

  alias Autolaunch.Chain.{Abi, Client}
  alias RegentChain.Address

  @user_operation "UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)"

  @type outcome :: :pending | :confirmed | :reverted

  @doc """
  `:pending` until the receipt exists, then `:confirmed` or `:reverted`.
  `client` reads at `latest` (`Autolaunch.Chain.Client`).
  """
  @spec outcome(RegentChain.Review.t(), String.t(), module()) ::
          {:ok, outcome()} | {:error, term()}
  def outcome(%{chain: chain, signer: signer, steps: steps}, hash, client \\ Client) do
    with {:ok, tx} when is_map(tx) <- client.transaction(chain, hash),
         true <- carries?(tx, chain, signer, steps) || {:error, :not_this_step},
         {:ok, receipt} when is_map(receipt) <- client.receipt(chain, hash) do
      status(receipt, tx, signer)
    else
      {:ok, nil} -> {:ok, :pending}
      error -> error
    end
  end

  defp carries?(tx, %{chain_id: chain_id}, signer, steps) do
    input = String.downcase(tx["input"] || "")

    quantity(tx["chainId"]) == chain_id and
      (Address.equal?(tx["from"], signer) or String.contains?(input, bare(signer))) and
      Enum.all?(steps, &(&1.value == "0x0" and String.contains?(input, bare(&1.to)))) and
      in_order?(input, Enum.map(steps, &bare(&1.data)))
  end

  # Each step's calldata appears after the one before it.
  defp in_order?(input, datas) do
    Enum.reduce_while(datas, 0, fn data, from ->
      case :binary.match(input, data, scope: {from, byte_size(input) - from}) do
        {at, length} -> {:cont, at + length}
        :nomatch -> {:halt, :missing}
      end
    end) != :missing
  end

  defp status(%{"status" => "0x0"}, _tx, _signer), do: {:ok, :reverted}

  defp status(%{"status" => "0x1"} = receipt, tx, signer) do
    if Address.equal?(tx["from"], signer),
      do: {:ok, :confirmed},
      else: operation(receipt["logs"], signer)
  end

  defp status(_receipt, _tx, _signer), do: {:ok, :pending}

  # The entry point's record of the signer's operation in this transaction:
  # its `success` word says whether the account's calls ran.
  defp operation(logs, signer) when is_list(logs) do
    topic = Abi.topic0(@user_operation)
    sender = "0x" <> String.pad_leading(bare(signer), 64, "0")

    Enum.find_value(logs, {:error, :not_this_step}, fn
      %{"topics" => [first, _hash, account | _rest], "data" => "0x" <> data} ->
        if String.downcase(first) == topic and String.downcase(account) == sender,
          do: success(data)

      _other ->
        nil
    end)
  end

  defp operation(_logs, _signer), do: {:error, :not_this_step}

  # `nonce` is the first data word and `success` the second.
  defp success(<<_nonce::binary-size(64), word::binary-size(64), _rest::binary>>),
    do: if(String.to_integer(word, 16) == 1, do: {:ok, :confirmed}, else: {:ok, :reverted})

  defp success(_data), do: {:error, :not_this_step}

  defp bare("0x" <> hex), do: String.downcase(hex)

  defp quantity("0x" <> hex) when hex != "", do: String.to_integer(hex, 16)
  defp quantity(_value), do: :unreadable
end
