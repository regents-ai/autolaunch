defmodule Autolaunch.CoveredCalls.Steps do
  @moduledoc """
  The wallet steps for one covered-call action, built on the server from the
  chain at the latest block, for a signer the caller has already proved is one
  of the acting account's own wallets (`Autolaunch.CoveredCalls.Market`).

  Eleven actions, each one review of the steps the wallet sends in turn:

    * `:list` — an exact stock approval, then `list`
    * `:fill` — an exact USDC approval, then `fill`
    * `:exercise` — an exact USDC approval, then `exercise`
    * `:cancel`, `:claim`, `:collect_strike` — one call each
    * `:bid` — an exact USDC approval of the bid's escrow, then `bid`, with
      the minimum sale the site sets (`Terms.min_sale/2`)
    * `:raise_bid` — an exact USDC approval of the raise's cost, then `raiseBid`
    * `:sell_to_bid` — an exact stock approval, then `sellToBid`
    * `:cancel_bid`, `:refund_bid` — one call each

  The approval is always a step of its own, so it stays pressable once done.
  An action the chain's own state makes certain to fail (nothing left to buy
  or sell into, outside the exercise window, too little stock or USDC, an
  approval not yet on the chain) comes back with `blocked` set to the reason
  and `approved` saying whether the allowance already covers it; its steps are
  still built, so a press the chain has since allowed reaches the wallet.
  A request that cannot name a real action (an unknown listing or bid, a zero
  amount, a new listing's or bid's expiry that is not one the site offers,
  `Terms.expiries/2`) is refused outright.
  """

  alias Autolaunch.Chain.{Abi, Client}
  alias Autolaunch.CoveredCalls.{Chain, Deployment, Terms}
  alias RegentChain.{Call, Review}

  @kinds [
    :list,
    :fill,
    :cancel,
    :exercise,
    :claim,
    :collect_strike,
    :bid,
    :raise_bid,
    :cancel_bid,
    :refund_bid,
    :sell_to_bid
  ]

  def kinds, do: @kinds

  @type prepared :: %{
          kind: atom(),
          chain: map(),
          steps: [map()],
          blocked: atom() | nil,
          facts: map()
        }

  @doc "The review for `request` signed by `signer`, or why there can be none."
  @spec prepare(map(), String.t()) :: {:ok, prepared()} | {:error, atom()}
  def prepare(%{kind: kind, symbol: symbol} = request, signer) when kind in @kinds do
    with {:ok, config} <- Deployment.current(),
         {:ok, market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, built} <- build(kind, request, market, signer, block, opts) do
      {:ok, Map.merge(built, %{kind: kind, chain: Client.chain(config.lab)})}
    end
  end

  def prepare(_request, _signer), do: {:error, :unknown_action}

  defp build(:list, request, market, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, strike} <- positive(request[:strike_per_token]),
         {:ok, premium} <- positive(request[:premium_per_token]),
         {:ok, expiry} <- expiry(request[:expiry], block),
         {:ok, effective_at} <- Chain.effective_at(market, block, opts),
         {:ok, stock} <- Chain.funds(market.stock, signer, market.contract, block, opts) do
      blocked =
        cond do
          Terms.corporate_action?(effective_at, expiry, block.timestamp) ->
            :corporate_action

          stock.balance < amount ->
            :not_enough_stock

          stock.allowance < amount ->
            :approve_first

          true ->
            nil
        end

      {:ok,
       %{
         steps:
           approval("stock_approval", market.stock, market.contract, amount) ++
             [
               Review.step(
                 "list",
                 market.contract,
                 Call.encode("list(uint256,uint256,uint256,uint64)", [
                   amount,
                   strike,
                   premium,
                   expiry
                 ])
               )
             ],
         blocked: blocked,
         approved: stock.allowance >= amount,
         facts: %{
           amount: amount,
           strike_per_token: strike,
           premium_per_token: premium,
           expiry: expiry
         }
       }}
    end
  end

  defp build(:fill, request, market, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, listing} <- listing(market, request, block, opts),
         {:ok, unit} <- Chain.unit(market, block, opts),
         {:ok, effective_at} <- Chain.effective_at(market, block, opts),
         {:ok, usdc} <- usdc(market, signer, block, opts) do
      premium = Terms.usdc_for(amount, listing.premium_per_token, unit)

      blocked =
        cond do
          block.timestamp >= listing.expiry ->
            :fills_closed

          Terms.corporate_action?(effective_at, listing.expiry, block.timestamp) ->
            :corporate_action

          Terms.available(listing) < amount ->
            :sold_out

          usdc.balance < premium ->
            :not_enough_usdc

          usdc.allowance < premium ->
            :approve_first

          true ->
            nil
        end

      {:ok,
       %{
         steps:
           approval("usdc_approval", usdc.token, market.contract, premium) ++
             [
               Review.step(
                 "fill",
                 market.contract,
                 Call.encode("fill(uint256,uint256)", [listing.id, amount])
               )
             ],
         blocked: blocked,
         approved: usdc.allowance >= premium,
         facts: %{
           listing_id: listing.id,
           amount: amount,
           premium: premium,
           fee: Terms.fee(premium),
           strike: Terms.usdc_for(amount, listing.strike_per_token, unit),
           expiry: listing.expiry
         }
       }}
    end
  end

  defp build(:exercise, request, market, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, listing} <- listing(market, request, block, opts),
         {:ok, position} <- Chain.position(market, listing.id, signer, block, opts),
         {:ok, unit} <- Chain.unit(market, block, opts),
         {:ok, usdc} <- usdc(market, signer, block, opts) do
      strike = Terms.usdc_for(amount, listing.strike_per_token, unit)

      blocked =
        cond do
          block.timestamp < listing.expiry -> :exercise_not_open
          Terms.stage(listing, block.timestamp) == :closed -> :exercise_closed
          position.held < amount -> :more_than_held
          usdc.balance < strike -> :not_enough_usdc
          usdc.allowance < strike -> :approve_first
          true -> nil
        end

      {:ok,
       %{
         steps:
           approval("usdc_approval", usdc.token, market.contract, strike) ++
             [
               Review.step(
                 "exercise",
                 market.contract,
                 Call.encode("exercise(uint256,uint256)", [listing.id, amount])
               )
             ],
         blocked: blocked,
         approved: usdc.allowance >= strike,
         facts: %{listing_id: listing.id, amount: amount, strike: strike, expiry: listing.expiry}
       }}
    end
  end

  defp build(:cancel, request, market, signer, block, opts) do
    with {:ok, listing} <- listing(market, request, block, opts) do
      blocked =
        cond do
          listing.seller != signer -> :not_seller
          Terms.available(listing) == 0 or listing.stock_returned -> :nothing_to_cancel
          true -> nil
        end

      one_call(:cancel, "cancel(uint256)", {:listing_id, listing.id}, market, blocked, %{
        unsold: Terms.available(listing)
      })
    end
  end

  defp build(:claim, request, market, signer, block, opts) do
    with {:ok, listing} <- listing(market, request, block, opts),
         {:ok, position} <- Chain.position(market, listing.id, signer, block, opts) do
      blocked = if position.claimable == 0, do: :nothing_to_claim

      one_call(:claim, "claim(uint256)", {:listing_id, listing.id}, market, blocked, %{
        amount: position.claimable
      })
    end
  end

  defp build(:collect_strike, request, market, signer, block, opts) do
    with {:ok, listing} <- listing(market, request, block, opts) do
      due = Terms.strike_due(listing)

      blocked =
        cond do
          listing.seller != signer -> :not_seller
          due == 0 -> :nothing_to_collect
          true -> nil
        end

      one_call(
        :collect_strike,
        "collectStrike(uint256)",
        {:listing_id, listing.id},
        market,
        blocked,
        %{amount: due}
      )
    end
  end

  defp build(:bid, request, market, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, strike} <- positive(request[:strike_per_token]),
         {:ok, premium} <- positive(request[:premium_per_token]),
         {:ok, expiry} <- expiry(request[:expiry], block),
         {:ok, unit} <- Chain.unit(market, block, opts),
         {:ok, effective_at} <- Chain.effective_at(market, block, opts),
         {:ok, usdc} <- usdc(market, signer, block, opts) do
      escrow = Terms.usdc_for(amount, premium, unit)
      min_sale = Terms.min_sale(amount, unit)

      blocked =
        cond do
          Terms.corporate_action?(effective_at, expiry, block.timestamp) -> :corporate_action
          usdc.balance < escrow -> :not_enough_usdc
          usdc.allowance < escrow -> :approve_first
          true -> nil
        end

      {:ok,
       %{
         steps:
           approval("usdc_approval", usdc.token, market.contract, escrow) ++
             [
               Review.step(
                 "bid",
                 market.contract,
                 Call.encode("bid(uint256,uint256,uint256,uint64,uint256)", [
                   amount,
                   strike,
                   premium,
                   expiry,
                   min_sale
                 ])
               )
             ],
         blocked: blocked,
         approved: usdc.allowance >= escrow,
         facts: %{
           amount: amount,
           strike_per_token: strike,
           premium_per_token: premium,
           expiry: expiry,
           min_sale: min_sale,
           escrow: escrow
         }
       }}
    end
  end

  defp build(:raise_bid, request, market, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, bid} <- bid(market, request, block, opts),
         {:ok, unit} <- Chain.unit(market, block, opts),
         {:ok, effective_at} <- Chain.effective_at(market, block, opts),
         {:ok, usdc} <- usdc(market, signer, block, opts) do
      escrow = Terms.raise_cost(bid, amount, unit)

      blocked =
        cond do
          bid.bidder != signer -> :not_bidder
          block.timestamp >= bid.expiry -> :bid_expired
          Terms.corporate_action?(effective_at, bid.expiry, block.timestamp) -> :corporate_action
          usdc.balance < escrow -> :not_enough_usdc
          usdc.allowance < escrow -> :approve_first
          true -> nil
        end

      {:ok,
       %{
         steps:
           approval("usdc_approval", usdc.token, market.contract, escrow) ++
             [
               Review.step(
                 "raise_bid",
                 market.contract,
                 Call.encode("raiseBid(uint256,uint256)", [bid.id, amount])
               )
             ],
         blocked: blocked,
         approved: usdc.allowance >= escrow,
         facts: %{bid_id: bid.id, amount: amount, escrow: escrow, expiry: bid.expiry}
       }}
    end
  end

  defp build(:sell_to_bid, request, market, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, bid} <- bid(market, request, block, opts),
         {:ok, unit} <- Chain.unit(market, block, opts),
         {:ok, effective_at} <- Chain.effective_at(market, block, opts),
         {:ok, stock} <- Chain.funds(market.stock, signer, market.contract, block, opts) do
      sale = Terms.sale(bid, amount, unit)
      left = Terms.available(bid)

      blocked =
        cond do
          block.timestamp >= bid.expiry -> :bid_expired
          left < amount -> :more_than_bid
          amount < bid.min_sale and amount != left -> :below_minimum_sale
          Terms.corporate_action?(effective_at, bid.expiry, block.timestamp) -> :corporate_action
          stock.balance < amount -> :not_enough_stock
          stock.allowance < amount -> :approve_first
          true -> nil
        end

      {:ok,
       %{
         steps:
           approval("stock_approval", market.stock, market.contract, amount) ++
             [
               Review.step(
                 "sell_to_bid",
                 market.contract,
                 Call.encode("sellToBid(uint256,uint256)", [bid.id, amount])
               )
             ],
         blocked: blocked,
         approved: stock.allowance >= amount,
         facts: %{
           bid_id: bid.id,
           amount: amount,
           premium: sale.premium,
           fee: sale.fee,
           receive: sale.receive,
           strike: Terms.usdc_for(amount, bid.strike_per_token, unit),
           expiry: bid.expiry
         }
       }}
    end
  end

  defp build(:cancel_bid, request, market, signer, block, opts) do
    with {:ok, bid} <- bid(market, request, block, opts),
         {:ok, unit} <- Chain.unit(market, block, opts) do
      blocked =
        cond do
          bid.bidder != signer -> :not_bidder
          Terms.available(bid) == 0 -> :nothing_to_cancel
          true -> nil
        end

      one_call(:cancel_bid, "cancelBid(uint256)", {:bid_id, bid.id}, market, blocked, %{
        unsold: Terms.available(bid),
        released: Terms.escrow_left(bid, unit)
      })
    end
  end

  defp build(:refund_bid, request, market, signer, block, opts) do
    with {:ok, bid} <- bid(market, request, block, opts),
         {:ok, refundable} <- Chain.refundable(market, bid.id, block, opts) do
      blocked =
        cond do
          bid.bidder != signer -> :not_bidder
          refundable == 0 -> :nothing_to_refund
          true -> nil
        end

      one_call(:refund_bid, "refundBid(uint256)", {:bid_id, bid.id}, market, blocked, %{
        amount: refundable
      })
    end
  end

  defp one_call(kind, signature, {key, id}, market, blocked, facts) do
    {:ok,
     %{
       steps: [Review.step(Atom.to_string(kind), market.contract, Call.encode(signature, [id]))],
       blocked: blocked,
       approved: true,
       facts: Map.put(facts, key, id)
     }}
  end

  # An approval is its own step, for exactly the amount.
  defp approval(name, token, spender, amount),
    do: [Review.step(name, token, Abi.encode_erc20("approve", [spender, amount]))]

  defp listing(market, %{listing_id: id}, block, opts) when is_integer(id) and id > 0,
    do: Chain.listing(market, id, block, opts)

  defp listing(_market, _request, _block, _opts), do: {:error, :unknown_listing}

  defp bid(market, %{bid_id: id}, block, opts) when is_integer(id) and id > 0,
    do: Chain.bid(market, id, block, opts)

  defp bid(_market, _request, _block, _opts), do: {:error, :unknown_bid}

  defp usdc(market, signer, block, opts) do
    with {:ok, token} <- Chain.usdc(market, block, opts),
         {:ok, funds} <- Chain.funds(token, signer, market.contract, block, opts),
         do: {:ok, Map.put(funds, :token, token)}
  end

  # A new listing's or bid's expiry: one of those the site offers at the
  # latest block, the list a page's ticket and a quote give.
  defp expiry(expiry, block) do
    cond do
      expiry in Terms.expiries(block.timestamp) -> {:ok, expiry}
      is_integer(expiry) and expiry <= block.timestamp -> {:error, :expiry_passed}
      true -> {:error, :expiry_not_offered}
    end
  end

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_value), do: {:error, :invalid_amount}
end
