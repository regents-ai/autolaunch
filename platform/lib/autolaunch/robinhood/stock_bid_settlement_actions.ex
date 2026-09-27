defmodule Autolaunch.Robinhood.StockBidSettlementActions do
  @moduledoc """
  The one boundary between a bidder's wallet and the end of a Robinhood
  memestock auction: returning what a bid did not spend, and claiming the
  launch tokens it won.

  Preparation reads Robinhood once, through
  `Autolaunch.Robinhood.StockBidSettlementChainClient`, and returns the steps
  for the page's review: the exit the auction accepts for this bid (a plain
  exit, or a partial exit with the checkpoint hints the auction needs when the
  bid was only partly filled), then the claim when there is one. Nothing is
  written anywhere: the review lives on the page, and `result/3` reads what a
  confirmed step did from its receipt.

  While bidding is still open, an outbid bid's unspent stock can come back
  early once the auction records a price above the bid's maximum. When the
  price has passed it but is not recorded yet, the review is a single
  `record` step, the auction's public `checkpoint()`; once that is confirmed,
  the exit is reviewed on its own against the price it stored.

  Every call binds to a wallet the account the session lease names links,
  read inside the lease at call time, and the bid must belong to that wallet
  on the auction's own record.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{CcaSettlement, Client, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.{Lab, StockBidSettlementChainClient}
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchOperations}
  alias RegentChain.{Address, Review}

  @new_decimals 18
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @doc """
  Reviews the settlement of one bid from `address`, which must be a wallet the
  signed-in account links and the bid's owner: the chain, the steps, what they
  return and the context `result/3` reads a receipt against. Refused, with the
  auction's own reason, when nothing can be done for the bid right now.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%{auction: auction, bid_id: bid_id}, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, config} <- robinhood_lab(),
         {:ok, auction} <- address(auction, :invalid_auction),
         {:ok, bid_id} <- bid_id(bid_id),
         {:ok, snapshot} <- snapshot(auction, bid_id, signer),
         :ok <- owned(snapshot, signer),
         {:ok, asset} <- listed_stock(snapshot.stock),
         {:ok, steps} <- eligible_steps(snapshot) do
      {:ok,
       %{
         chain: Client.chain(config),
         steps: Enum.map(steps, &Review.step(&1.name, snapshot.auction, &1.data)),
         facts: facts(asset, snapshot, steps),
         context: %{
           auction: snapshot.auction,
           onchain_bid_id: snapshot.bid.id,
           signer: signer,
           stock_decimals: snapshot.stock_decimals
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
             context.auction,
             context.onchain_bid_id,
             context.signer
           ) do
      %{
        "tokens_filled_units" => Rpc.format_units(exit.tokens_filled, @new_decimals),
        "stock_refunded_units" => Rpc.format_units(exit.currency_refunded, context.stock_decimals)
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
             context.auction,
             context.onchain_bid_id,
             context.signer
           ) do
      %{"tokens_claimed_units" => Rpc.format_units(claim.tokens_claimed, @new_decimals)}
    else
      _not_this_bid -> nil
    end
  end

  def result(_context, _record, _logs), do: nil

  @doc """
  When this bid's unspent stock can come back, read at one pinned block and
  opening nothing: `CcaSettlement.return_status/1`, with the auction's own
  refusal as the error.
  """
  @spec return_status(map()) :: {:ok, term()} | {:error, term()}
  def return_status(%{auction: auction, bid_id: bid_id, owner: owner}) do
    with {:ok, _config} <- robinhood_lab(),
         {:ok, auction} <- address(auction, :invalid_auction),
         {:ok, bid_id} <- bid_id(bid_id),
         {:ok, snapshot} <- snapshot(auction, bid_id, owner) do
      case CcaSettlement.return_status(snapshot) do
        {:refused, reason} -> unavailable(reason)
        status -> {:ok, status}
      end
    end
  end

  # Inputs

  defp bid_id(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp bid_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> {:ok, id}
      _other -> unavailable(:bid_not_found)
    end
  end

  defp bid_id(_value), do: unavailable(:bid_not_found)

  defp owned(%{bid: %{owner: owner}}, signer) do
    if Address.equal?(owner, signer), do: :ok, else: unavailable(:not_your_bid)
  end

  defp listed_stock(stock) do
    case Assets.fetch(Lab.chain_id(), stock) do
      {:ok, asset} -> {:ok, asset}
      _missing -> unavailable(:stock_not_listed)
    end
  end

  # The steps the auction accepts right now: the exit first, then the claim
  # when one is open; a bid already returned may only claim; an outbid bid
  # whose passed price is not recorded yet may only record it.
  defp eligible_steps(%{
         graduated?: false,
         exit: {:refused, :already_exited},
         bid: %{exited_block: exited_block, tokens_filled: 0}
       })
       when exited_block > 0,
       do: unavailable(:failed_bid_returned)

  defp eligible_steps(%{exit: {:refused, :already_exited}, claim: %{} = claim}),
    do: {:ok, [claim_step(claim)]}

  defp eligible_steps(%{exit: {:refused, :price_not_recorded}}), do: {:ok, [record_step()]}

  defp eligible_steps(%{exit: %{} = exit, claim: claim}),
    do: {:ok, [exit_step(exit) | claim_steps(claim)]}

  defp eligible_steps(snapshot), do: unavailable(refusal_reason(snapshot))

  defp refusal_reason(%{exit: {:refused, :already_exited}, claim: {:refused, reason}}), do: reason
  defp refusal_reason(%{exit: {:refused, reason}}), do: reason

  defp claim_steps(%{} = claim), do: [claim_step(claim)]
  defp claim_steps({:refused, _reason}), do: []

  defp record_step, do: %{name: "record", data: LabAbi.selector("checkpoint()")}

  defp exit_step(exit),
    do: %{
      name: "exit",
      data: exit.data,
      tokens_filled: exit.tokens_filled,
      stock_refunded: exit.currency_refunded
    }

  defp claim_step(claim),
    do: %{name: "claim", data: claim.data, tokens_claimed: claim.tokens_claimed}

  # What the review states before anything is signed, in the auction's units:
  # the bid, its most per token, the final price, the stock an exit sends back
  # and the tokens it fills, and the tokens a claim delivers.
  defp facts(asset, snapshot, steps) do
    decimals = snapshot.stock_decimals
    exit = Enum.find(steps, &(&1.name == "exit"))
    claim = Enum.find(steps, &(&1.name == "claim"))

    %{
      stock_symbol: asset.symbol,
      graduated: snapshot.graduated?,
      bid_amount: Rpc.format_units(snapshot.bid.amount, decimals),
      max_price: price(snapshot.bid.max_price_q96, decimals),
      final_price: price(snapshot.final_clearing_price_q96, decimals),
      stock_refunded: exit && Rpc.format_units(exit.stock_refunded, decimals),
      tokens_filled: exit && Rpc.format_units(exit.tokens_filled, @new_decimals),
      tokens_claimed: claim && Rpc.format_units(claim.tokens_claimed, @new_decimals)
    }
  end

  defp price(q96, decimals), do: Amounts.format_cca_price(q96, decimals, @new_decimals)

  # Chain snapshot

  defp robinhood_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:robinhood_unavailable)
    end
  end

  defp snapshot(auction, bid_id, signer) do
    case StockBidSettlementChainClient.snapshot(%{
           auction: auction,
           bid_id: bid_id,
           signer: signer
         }) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # Session and wallet identity

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> unavailable(:authentication_required)
    end
  end

  defp lease(opts) do
    case Keyword.get(opts, :context) do
      %{session_lease: %{lineage: lineage, account_id: account_id}}
      when is_binary(lineage) and is_integer(account_id) ->
        {:ok, %{lineage: lineage, account_id: account_id}}

      _absent ->
        unavailable(:session_lease_required)
    end
  end

  # The wallet has to be one the leased account links, read now: never a guess.
  defp current_wallet(address, actor, opts) do
    with {:ok, candidate} <- address(address, :invalid_address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: linked_wallet(account, candidate)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp linked_wallet(%{wallet_addresses: wallets}, candidate) when is_list(wallets) do
    if Enum.any?(wallets, &Address.equal?(&1, candidate)),
      do: {:ok, candidate},
      else: unavailable(:wrong_signer)
  end

  defp linked_wallet(_account, _candidate), do: unavailable(:wrong_signer)

  # Shared helpers

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
