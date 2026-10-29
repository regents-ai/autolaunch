defmodule Autolaunch.Chain.Calls do
  @moduledoc """
  What a review the wallet sent as one atomic batch (EIP-5792
  `wallet_sendCalls`) did, read at the latest block of the review's chain from
  the transaction the wallet's own status report named.

  A batch is never one of the review's steps on its own: an account that
  batches itself (EIP-7702) sends it to its own address, and a smart account
  (ERC-4337) has a bundler send it to the entry point. So instead of the step's
  target and calldata, the transaction must carry every step's exact target and
  calldata, in the review's order, on the review's chain. A step's calldata is
  matched without its Builder Code suffix (`RegentChain.BuilderCode.call/1`), which
  a wallet may rewrite with its own. It is the review's
  only when it is sent by the review's signer, or names the signer as the smart
  account that ran it. Anything else is no answer about the review
  (`{:error, :not_this_step}`).

  A batch that is the review's and ran is `:confirmed` when its receipt holds
  the record the batch exists to make (`proof`): the named event, from the
  named contract, with the signer as its first indexed word. Without it the
  batch is `:nothing`: it ran, but the contract made no such record for the
  signer (a claim with nothing owed pays nothing and records nothing). For a claim that is the launch splitter's
  `Claimed(account, token, amount)` for the signer. A smart account's
  transaction succeeds even when the account's own calls fail, so its outcome
  is also the canonical entry point's own record of the signer's operation
  (EntryPoint v0.6, v0.7 or v0.8); the same event from any other contract is
  not that record.
  """

  alias Autolaunch.Chain.{Abi, Client}
  alias RegentChain.{Address, BuilderCode}

  @user_operation "UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)"
  # The canonical ERC-4337 entry points, at the same address on every chain.
  @entry_points [
    "0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789",
    "0x0000000071727de22e5e9d8baf0edac6f37da032",
    "0x4337084d9e255ff0702461cf8895ce9e3b5ff108"
  ]

  @type outcome :: :pending | :confirmed | :nothing | :reverted
  @type proof :: %{emitter: String.t(), event: String.t()}

  @doc """
  `:pending` until the receipt exists, then `:confirmed`, `:nothing` or
  `:reverted`.
  `proof` names the event the batch must write for the signer; `client`
  reads at `latest` (`Autolaunch.Chain.Client`).
  """
  @spec outcome(RegentChain.Review.t(), String.t(), proof(), module()) ::
          {:ok, outcome()} | {:error, term()}
  def outcome(%{chain: chain, signer: signer, steps: steps}, hash, proof, client \\ Client) do
    with {:ok, tx} when is_map(tx) <- client.transaction(chain, hash),
         true <- carries?(tx, chain, signer, steps) || {:error, :not_this_step},
         {:ok, receipt} when is_map(receipt) <- client.receipt(chain, hash) do
      status(receipt, tx, signer, proof)
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
      in_order?(input, Enum.map(steps, &bare(BuilderCode.call(&1.data))))
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

  defp status(%{"status" => "0x0"}, _tx, _signer, _proof), do: {:ok, :reverted}

  defp status(%{"status" => "0x1"} = receipt, tx, signer, proof) do
    logs = if is_list(receipt["logs"]), do: receipt["logs"], else: []

    ran =
      if Address.equal?(tx["from"], signer),
        do: {:ok, :confirmed},
        else: operation(logs, signer)

    case ran do
      {:ok, :confirmed} -> proved(logs, signer, proof)
      other -> other
    end
  end

  defp status(_receipt, _tx, _signer, _proof), do: {:ok, :pending}

  # The entry point's record of the signer's operation in this transaction:
  # its `success` word says whether the account's calls ran.
  defp operation(logs, signer) do
    topic = Abi.topic0(@user_operation)
    sender = word(signer)

    Enum.find_value(logs, {:error, :not_this_step}, fn
      %{"address" => emitter, "topics" => [first, _hash, account | _rest], "data" => "0x" <> data} ->
        if String.downcase(emitter) in @entry_points and String.downcase(first) == topic and
             String.downcase(account) == sender,
           do: success(data)

      _other ->
        nil
    end)
  end

  # The batch wrote what it exists to write, for the signer, from the right contract.
  defp proved(logs, signer, %{emitter: emitter, event: event}) do
    topic = Abi.topic0(event)
    account = word(signer)

    written? =
      Enum.any?(logs, fn
        %{"address" => from, "topics" => [first, named | _rest]} ->
          Address.equal?(from, emitter) and String.downcase(first) == topic and
            String.downcase(named) == account

        _other ->
          false
      end)

    if written?, do: {:ok, :confirmed}, else: {:ok, :nothing}
  end

  defp word(address), do: "0x" <> String.pad_leading(bare(address), 64, "0")

  # `nonce` is the first data word and `success` the second.
  defp success(<<_nonce::binary-size(64), word::binary-size(64), _rest::binary>>),
    do: if(String.to_integer(word, 16) == 1, do: {:ok, :confirmed}, else: {:ok, :reverted})

  defp success(_data), do: {:error, :not_this_step}

  defp bare("0x" <> hex), do: String.downcase(hex)

  defp quantity("0x" <> hex) when hex != "", do: String.to_integer(hex, 16)
  defp quantity(_value), do: :unreadable
end
