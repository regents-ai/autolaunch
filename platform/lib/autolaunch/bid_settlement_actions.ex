defmodule Autolaunch.BidSettlementActions do
  @moduledoc """
  The one boundary between a bidder and the auction after bidding has ended.

  Preparation reads the auction once, through `LabBidSettlementChainClient`,
  which lets the auction itself say what settling this bid position would do
  right now: whether the auction has ended, whether it graduated, whether the
  bid has been exited, what `exitBid` (or `exitPartiallyFilledBid` with derived
  checkpoint hints) would return, and what `claimTokens` would deliver. The
  exact eligible steps and their calldata come back for the page's review;
  anything the auction refuses becomes a reason code rather than a wallet
  prompt.

  While bidding is still open, an outbid bid's unspent money can come back
  early once the auction records a price above the bid's maximum. When the
  price has passed it but is not recorded yet, the review is a single
  `record` step, the auction's public `checkpoint()`; once that is confirmed,
  the exit is reviewed on its own against the price it stored.

  Nothing is stored while a settlement is on its way: the review lives on the
  page, and `result/3` reads what a confirmed step did from its receipt.
  """

  require Ash.Query

  alias Autolaunch.{Bid, Lab, LabAbi, LabBidSettlementChainClient}
  alias Autolaunch.Chain.{CcaSettlement, Client, Rpc}
  alias Autolaunch.Stocks.LaunchOperations
  alias RegentChain.{Address, Review}

  @domain Autolaunch
  @new_decimals 18

  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  @doc """
  Reviews one settlement from `address`, which must be a wallet the signed-in
  account links and the bid's owner: the chain, the steps, what they return
  and the context `result/3` reads a receipt against.

  The steps are only those the auction would accept right now: the exit that
  returns unspent currency and records the fill, then the claim of the launch
  token when the auction graduated, the claim block has passed and the bid has
  fill. A position nothing can be done for yet is refused with the auction's
  own reason.
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(bid_position_id, address, opts) do
    with {:ok, %{actor: actor, signer: signer}} <-
           LaunchOperations.signed_in_wallet(address, opts, Bid),
         {:ok, position} <- owned_position(bid_position_id, actor),
         :ok <- owner(position.owner_address, signer),
         {:ok, bid_id} <- onchain_bid_id(position),
         {:ok, snapshot} <- snapshot(position.auction_address, bid_id, signer),
         :ok <- owner(snapshot.bid.owner, signer),
         {:ok, steps} <- eligible_steps(snapshot),
         {:ok, config} <- lab() do
      auction = position.auction

      {:ok,
       %{
         chain: Client.chain(config),
         steps: Enum.map(steps, &Review.step(&1.name, snapshot.auction, &1.data)),
         facts: facts(auction, snapshot, steps),
         context: %{
           bid_id: position.bid_id,
           auction_address: snapshot.auction,
           onchain_bid_id: snapshot.bid.id,
           signer: signer,
           currency_decimals: auction.quote_token_decimals,
           claim_next?: Enum.any?(steps, &(&1.name == "claim"))
         }
       }}
    end
  end

  @doc """
  What a confirmed exit or claim did, read from its receipt's logs: only the
  auction's own `BidExited` or `TokensClaimed` for this bid and this owner
  counts. `nil` for a recorded price, or for logs that record something else.
  """
  @spec result(map(), String.t(), [map()]) :: map() | nil
  def result(context, "exit", logs) do
    with {:ok, config} <- Lab.current(),
         {:ok, exit} <-
           CcaSettlement.exited(
             Lab.abi!(config, :auction),
             logs,
             context.auction_address,
             context.onchain_bid_id,
             context.signer
           ) do
      %{
        "tokens_filled" => Integer.to_string(exit.tokens_filled),
        "tokens_filled_units" => Rpc.format_units(exit.tokens_filled, @new_decimals),
        "currency_refunded" => Integer.to_string(exit.currency_refunded),
        "currency_refunded_units" =>
          Rpc.format_units(exit.currency_refunded, context.currency_decimals)
      }
    else
      _not_this_bid -> nil
    end
  end

  def result(context, "claim", logs) do
    with {:ok, config} <- Lab.current(),
         {:ok, claim} <-
           CcaSettlement.claimed(
             Lab.abi!(config, :auction),
             logs,
             context.auction_address,
             context.onchain_bid_id,
             context.signer
           ) do
      %{
        "tokens_claimed" => Integer.to_string(claim.tokens_claimed),
        "tokens_claimed_units" => Rpc.format_units(claim.tokens_claimed, @new_decimals)
      }
    else
      _not_this_bid -> nil
    end
  end

  def result(_context, _record, _logs), do: nil

  @doc """
  When this position's unspent money can come back, read at one pinned block
  and opening nothing: `CcaSettlement.return_status/1`, with the auction's own
  refusal as the error.
  """
  @spec return_status(map()) :: {:ok, term()} | {:error, term()}
  def return_status(position) do
    with {:ok, bid_id} <- onchain_bid_id(position),
         {:ok, snapshot} <- snapshot(position.auction_address, bid_id, position.owner_address) do
      case CcaSettlement.return_status(snapshot) do
        {:refused, reason} -> unavailable(reason)
        status -> {:ok, status}
      end
    end
  end

  # Reviews

  # The exact eligible steps. The exit comes first whenever the auction accepts
  # it; the claim follows only when the auction would deliver tokens right after
  # that exit (graduated, claim block reached, fill above zero). An already
  # exited bid with claimable fill has only the claim. An outbid bid whose
  # passed price is not recorded yet has only the record step.
  defp eligible_steps(%{exit: {:refused, :already_exited}, claim: %{} = claim}),
    do: {:ok, [claim_step(claim)]}

  defp eligible_steps(%{exit: {:refused, :price_not_recorded}}), do: {:ok, [record_step()]}

  defp eligible_steps(%{exit: %{} = exit, claim: claim}),
    do: {:ok, [exit_step(exit) | claim_steps(claim)]}

  defp eligible_steps(snapshot), do: unavailable(refusal_reason(snapshot))

  # Why nothing can be settled for this position right now, in the auction's own answer.
  defp refusal_reason(%{exit: {:refused, :already_exited}, claim: {:refused, reason}}),
    do: reason

  defp refusal_reason(%{exit: {:refused, reason}}), do: reason

  defp claim_steps(%{} = claim), do: [claim_step(claim)]
  defp claim_steps({:refused, _reason}), do: []

  defp record_step, do: %{name: "record", data: LabAbi.selector("checkpoint()")}

  defp exit_step(exit),
    do: %{
      name: "exit",
      data: exit.data,
      tokens_filled: exit.tokens_filled,
      currency_refunded: exit.currency_refunded
    }

  defp claim_step(claim),
    do: %{name: "claim", data: claim.data, tokens_claimed: claim.tokens_claimed}

  # What the review returns, in the auction's units: the currency an exit
  # sends back and the tokens it fills, and the tokens a claim delivers.
  defp facts(auction, snapshot, steps) do
    exit = Enum.find(steps, &(&1.name == "exit"))
    claim = Enum.find(steps, &(&1.name == "claim"))

    %{
      currency_symbol: auction.quote_token_symbol,
      token_symbol: auction.token_symbol,
      graduated: snapshot.graduated?,
      currency_refunded:
        exit && Rpc.format_units(exit.currency_refunded, auction.quote_token_decimals),
      tokens_filled: exit && Rpc.format_units(exit.tokens_filled, @new_decimals),
      tokens_claimed: claim && Rpc.format_units(claim.tokens_claimed, @new_decimals)
    }
  end

  # Positions

  defp owned_position(bid_position_id, actor) do
    with {:ok, uuid} <- cast_uuid(bid_position_id),
         {:ok, position} <-
           Bid
           |> Ash.Query.for_read(:mine, %{}, domain: @domain, actor: actor)
           |> Ash.Query.filter(id == ^uuid)
           |> Ash.read_one(domain: @domain, actor: actor) do
      if position, do: {:ok, position}, else: unavailable(:not_your_bid)
    else
      {:error, _reason} -> unavailable(:not_your_bid)
    end
  end

  defp cast_uuid(value) do
    case Ash.Type.UUID.cast_input(value, []) do
      {:ok, uuid} when not is_nil(uuid) -> {:ok, uuid}
      _invalid -> unavailable(:not_your_bid)
    end
  end

  defp onchain_bid_id(%{onchain_bid_id: id, auction_address: address})
       when is_binary(id) and is_binary(address),
       do: {:ok, String.to_integer(id)}

  defp onchain_bid_id(_position), do: unavailable(:position_not_on_chain)

  # The stored position and the auction's own record of the bid both have to
  # name the signer as the owner.
  defp owner(owner, signer) do
    if Address.equal?(owner, signer), do: :ok, else: unavailable(:not_your_bid)
  end

  # Chain snapshot

  # The fork's reading (`LabBidSettlementChainClient`), or the answers a test installed.
  defp snapshot(auction_address, bid_id, signer) do
    client =
      Application.get_env(
        :autolaunch,
        :autolaunch_bid_settlement_chain_client,
        LabBidSettlementChainClient
      )

    case client.snapshot(%{auction: auction_address, bid_id: bid_id, signer: signer}) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:chain_unavailable)
    end
  end

  defp unavailable(reason),
    do: {:error, Ash.Error.Invalid.Unavailable.exception(resource: Bid, reason: reason)}
end
