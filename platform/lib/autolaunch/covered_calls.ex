defmodule Autolaunch.CoveredCalls do
  @moduledoc """
  Covered calls on Base stock tokens: a seller locks stock and lists calls on
  it; any person or agent buys them for a premium in USDC; during the 24 hours
  after the Friday expiry a holder may pay the strike for the stock. The
  contract (`contracts/covered-calls`) is the record; see
  `platform/docs/covered-calls-design.md`.
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

      description "List the covered calls on one Base stock token, as its contract holds them at the latest block: every listing with its seller, strike_per_token and premium_per_token (micro-USDC per whole token), expiry (a Friday at 21:00 UTC, Unix seconds), amount, filled and available (raw token units, unit per whole token) and stage (open, sold, exercise or closed), the stock's multiplier and its reference price. Reads only. The reading is shared and may be up to five minutes old; read_at says when it was taken."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :covered_call_quote, Autolaunch.CoveredCalls.Market, :quote do
      title("Suggest a covered-call premium")

      description "Suggest a premium per whole token for a covered call on one Base stock token at a strike (micro-USDC per whole token) and weekly expiry (a Friday at 21:00 UTC, Unix seconds), from the stock's reference price. A guide for a seller only: the contract enforces nothing from it, and it is refused while the reference price is more than four days old. Reads only."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :covered_call_positions, Autolaunch.CoveredCalls.Market, :positions_answer do
      title("Read my covered calls on a stock")

      description "Read my person's covered calls on one Base stock token, for the wallet they signed in with, at the latest block: the listings it sold and, on every listing, the calls it may exercise (held) and the stock it may claim (claimable), in raw token units. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :prepare_covered_call, Autolaunch.CoveredCalls.Market, :prepare_answer do
      title("Prepare a covered-call step")

      description "Prepare the wallet steps for one covered-call action on a Base stock token: list (amount, strike_per_token, premium_per_token, expiry), fill (listing_id, amount), exercise (listing_id, amount), cancel, claim or collect_strike (listing_id). The steps are for one of my person's own wallets: signer when given, otherwise the wallet they signed in with; any other wallet is refused. The site only prepares: the wallet's own key signs and sends each step in turn (to, data, value on chain), and money moves only then. approved says whether the allowance already covers the action; blocked names, in code and words, a reason the chain's current state makes the action certain to fail, and the steps are still returned. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end
  end

  # The four operations every agent surface runs, by the names the hosted MCP
  # tools carry, then the readings the page draws from.
  resources do
    resource Autolaunch.CoveredCalls.Market do
      define :covered_call_book, action: :book_answer, args: [:symbol]
      define :covered_call_quote, action: :quote, args: [:symbol, :strike_per_token, :expiry]
      define :covered_call_positions, action: :positions_answer, args: [:symbol]
      define :prepare_covered_call, action: :prepare_answer, args: [:symbol, :kind]
      define :read_covered_call_book, action: :book, args: [:symbol]
      define :read_covered_call_positions, action: :positions, args: [:symbol]
      define :prepare_covered_call_steps, action: :prepare, args: [:symbol, :kind]
    end
  end
end
