defmodule Autolaunch.RpcClient do
  @moduledoc """
  The production Base client for bidding, which prepares nothing yet.

  `submitBid` takes `prevTickPriceQ96`, and the only sources for it today are an
  unbounded walk from the floor price or the floor itself. Neither is a reviewed
  answer, so `snapshot/1` refuses before it opens a connection; `regent-alv1.6`
  and `490.8.2/.3` own the bounded source that replaces this refusal.

  `verify/3` is complete, because a hash may still have to be told the truth
  about. It reads only canonical state: a receipt above the safe head, or one in
  a block that is no longer canonical, stays pending rather than becoming an
  answer, and an approval advances only once its own allowance really holds.
  """

  @behaviour Autolaunch.ChainClient

  alias Autolaunch.Chain.{Abi, AuctionAbi, Permit2Abi, Rpc}

  @rpc_opts [client_key: :autolaunch_bid_http_client, log_scope: "autolaunch bid"]

  @impl true
  def snapshot(_request), do: {:error, :bid_preparation_unavailable}

  @impl true
  def verify(envelope, step, hash) do
    %{"to" => to, "data" => data} = step(envelope, step)

    with {:ok, block} <- Rpc.safe_block(@rpc_opts),
         {:ok, settled} <-
           Rpc.canonical_outcome(hash, envelope["expected_signer"], to, data, block, @rpc_opts),
         do: settled(settled, envelope, step, block)
  end

  defp settled(:pending, _envelope, _step, _block), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _block), do: {:ok, %{outcome: :reverted}}
  defp settled({:success, logs}, envelope, step, block), do: proved(envelope, step, logs, block)

  # The approval's own event and the allowance it claims to have left behind are
  # separate facts. This transaction was prepared here to set one exact
  # allowance, so only that exact allowance proves it did what it was reviewed
  # to do; anything else is a state this review cannot vouch for.
  defp proved(envelope, :token_approval, logs, block) do
    %{"to" => token, "amount" => amount} = step(envelope, :token_approval)
    amount = String.to_integer(amount)
    signer = envelope["expected_signer"]
    permit2 = Permit2Abi.address()

    with true <- Abi.approval_recorded?(logs, token, signer, permit2, amount),
         {:ok, allowance} <-
           Rpc.call_uint(
             token,
             Abi.encode_erc20("allowance", [signer, permit2]),
             block,
             @rpc_opts
           ) do
      {:ok, %{outcome: outcome(allowance == amount)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Permit2 emits its own Approval, but only the stored allowance decides whether
  # this auction may really draw the currency, so that is what is read — and it
  # has to be exactly the amount and expiry this review granted.
  defp proved(envelope, :permit2_approval, _logs, block) do
    %{"amount" => amount, "expiration" => expiration} = step(envelope, :permit2_approval)

    with {:ok, words} <-
           Rpc.call_words(
             Permit2Abi.address(),
             Permit2Abi.encode_allowance(
               envelope["expected_signer"],
               argument(envelope, "currency"),
               envelope["to"]
             ),
             block,
             3,
             @rpc_opts
           ),
         {:ok, granted} <- Permit2Abi.decode_allowance(words) do
      {:ok,
       %{
         outcome:
           outcome(
             granted == %{
               amount: String.to_integer(amount),
               expiration: String.to_integer(expiration)
             }
           )
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # The event, not the receipt, carries the bid: its id is adopted from the one
  # `BidSubmitted` this auction emitted for this owner at exactly these terms.
  defp proved(envelope, :bid, logs, _block) do
    case AuctionAbi.submitted_bid_id(
           logs,
           envelope["to"],
           envelope["expected_signer"],
           integer_argument(envelope, "max_price_q96"),
           integer_argument(envelope, "amount_atomic")
         ) do
      {:ok, bid_id} -> {:ok, %{outcome: :confirmed, onchain_bid_id: Integer.to_string(bid_id)}}
      :error -> {:ok, %{outcome: :unverified}}
    end
  end

  defp outcome(true), do: :confirmed
  defp outcome(false), do: :unverified

  defp step(envelope, step) do
    current = Atom.to_string(step)
    Enum.find(argument(envelope, "steps"), &(&1["step"] == current))
  end

  defp argument(envelope, key), do: envelope["arguments"][key]
  defp integer_argument(envelope, key), do: envelope |> argument(key) |> String.to_integer()
end
