defmodule Autolaunch.CoveredCalls do
  @moduledoc """
  Covered calls on Base stock tokens: a seller locks stock and lists calls on
  it; any person or agent buys them for a premium in USDC, or posts a standing
  bid with its premium escrowed that a seller sells into and is paid at once;
  during the 24 hours after the Friday expiry a holder may pay the strike for
  the stock. The contract (`CoveredCallsV2`, `contracts/covered-calls-v2`) is
  the record; see `platform/docs/covered-calls-design.md`.
  """

  use Ash.Domain, otp_app: :autolaunch, extensions: [AshAi]

  @doc "The refusal an operation answered with, as the atom its surfaces turn into words."
  def reason(%{errors: [%Autolaunch.CoveredCalls.Refused{reason: reason} | _]}), do: reason
  def reason(reason) when is_atom(reason), do: reason
  def reason(_error), do: :chain_unavailable

  # The hosted MCP tools: the four operations every agent surface runs, each with
  # its browser tool's title, listed and run only as their policies allow (only
  # while the site offers covered calls, and never by a connected app calling as
  # itself).
  tools do
    tool :covered_call_book, Autolaunch.CoveredCalls.Market, :book_answer do
      title("List covered calls on a stock")

      description "List the covered calls on one Base stock token, as its contract holds them at the latest block: the open listings, the best for a buyer first (the soonest expiry, then the lowest strike plus premium), each with its seller, strike_per_token and premium_per_token (micro-USDC per whole token), expiry (a Friday at 21:00 UTC, Unix seconds), amount, filled and available (raw token units, unit per whole token); the open bids, standing offers to buy calls whose premium is already escrowed, the best for a seller first (the soonest expiry, then the most a seller ends with per token at the reference price: the premium plus the strike, the strike counted no higher than that price), each with its bidder, strike_per_token, premium_per_token, expiry, amount, filled, available and min_sale (the fewest raw units one sale into it may be, unless it sells all that is left); only those on the expiries the site offers, at most fifty of each for each expiry, with listings_total and bids_total counting all that are open on those expiries, and no listing or bid with less than one whole token left; the stock's multiplier and its reference price; and market, which names the stock by its issuer, its chain and its exact address, beside the address of its covered-calls contract. Reads only. The reading is shared and may be up to five minutes old; read_at says when it was taken."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :covered_call_quote, Autolaunch.CoveredCalls.Market, :quote do
      title("Suggest a covered-call premium")

      description "Quote a covered call on one Base stock token before listing it, for a weekly expiry: the stock it is on (market: its issuer, chain and exact addresses); the stock's reference price (spot_per_token, micro-USDC per whole token) and when its feed last updated it; the next four weekly expiries a listing may take, leaving out Fridays when the US stock market is shut or closes early, each with its exercise window (Unix seconds), and the chosen one's term in whole days (term_days); three suggested strikes above the reference price (presets), each with how far above it is as a fraction and a suggested premium per whole token; and, for the chosen strike (the middle suggestion when none is given) and premium (the suggestion when none is given), what a listing of amount raw token units pays if all of it is bought at once and all of it exercised (receipt): the premium, the 1% fee, what the seller keeps, the strike, the stock's worth at the reference price, and the premium kept as a fraction of that worth for the term (net_premium_yield, not a yearly rate). Without an amount the per-token figures still come back and the totals are null. Every USDC figure is what the contract counts, rounded up. A guide for a seller only: the contract enforces no suggestion, and the quote is refused while the reference price is more than four days old. Reads only."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :covered_call_positions, Autolaunch.CoveredCalls.Market, :positions_answer do
      title("Read my covered calls on a stock")

      description "Read my person's covered calls on one Base stock token, for the wallet they signed in with, at the latest block: the stock they are on (market: its issuer, chain and exact addresses), the listings it sold, each with its stage (open, sold, exercise, closed or stopped), on every listing the calls it holds (held) with the strike_per_token to pay and the one day they can be exercised in (from expiry until exercise_closes_at; nothing is exercised automatically, and calls not exercised by then end with the premium not returned) and the stock it may claim now (claimable), every bid it made with its stage (open, sold, cancelled or expired) and the micro-USDC a refund would send it now (refundable), leaving out a bid stopped with nothing sold and nothing left to refund, and the stock in the wallet itself (balance), the most it can list now, in raw token units. A sale into a bid opens a listing like any other: it shows as the seller's sold listing and the bidder's held calls. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :prepare_covered_call, Autolaunch.CoveredCalls.Market, :prepare_answer do
      title("Prepare a covered-call step")

      description "Prepare the wallet steps for one covered-call action on a Base stock token: list (amount, strike_per_token, premium_per_token, expiry), fill (listing_id, amount), exercise (listing_id, amount), cancel, claim or collect_strike (listing_id); bid (amount, strike_per_token, premium_per_token, expiry: escrows the whole premium in USDC, and each sale into it must be at least one whole token, or the whole bid when it asks for less, unless it sells all that is left), raise_bid (bid_id, amount: asks for more at the same terms and escrows the premium that adds), sell_to_bid (bid_id, amount: locks the stock as calls held by the bidder and pays the premium less the 1% fee at once), cancel_bid or refund_bid (bid_id). facts gives the action's figures exactly as the contract counts them: for bid and raise_bid the escrow it takes, for sell_to_bid the premium, the fee and what lands in the wallet (receive). market names the stock by its issuer, its chain and its exact address, beside the address of its covered-calls contract. The steps are for one of my person's own wallets: signer when given, otherwise the wallet they signed in with; any other wallet is refused. The site only prepares: the wallet's own key signs and sends each step in turn (to, data, value on chain), and money moves only then. approved says whether the allowance already covers the action; blocked names, in code and words, a reason the chain's current state makes the action certain to fail, and the steps are still returned. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end
  end

  # The four operations every agent surface runs, by the names the hosted MCP
  # tools carry, then the readings the page draws from.
  resources do
    resource Autolaunch.CoveredCalls.Market do
      define :covered_call_book, action: :book_answer, args: [:symbol]
      define :covered_call_quote, action: :quote, args: [:symbol]
      define :covered_call_positions, action: :positions_answer, args: [:symbol]
      define :prepare_covered_call, action: :prepare_answer, args: [:symbol, :kind]
      define :read_covered_call_book, action: :book, args: [:symbol]
      define :read_covered_call_offer, action: :offer, args: [:symbol, :kind, :id]
      define :read_covered_call_positions, action: :positions, args: [:symbol]
      define :prepare_covered_call_steps, action: :prepare, args: [:symbol, :kind]
    end
  end
end
