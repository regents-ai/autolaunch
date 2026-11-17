defmodule Autolaunch.Earn do
  @moduledoc """
  Earn: a person or agent lends USDC on Base through a market such as Aave V3,
  sees its balance grow, and takes it back, all from Autolaunch. The site only
  prepares the wallet steps; the wallet's own key signs and sends them, and
  the market's contracts hold the funds. The products are plain data
  (`Autolaunch.Earn.Catalog`); every figure is read from the chain at the
  latest block (`Autolaunch.Earn.Chain`), and nothing is stored. See
  `platform/docs/earn-design.md`.
  """

  use Ash.Domain, otp_app: :autolaunch, extensions: [AshAi]

  @doc """
  The refusal an operation answered with, as the atom its surfaces turn into
  words: the reason it named (`Autolaunch.Earn.Refused`), or `:invalid_request`
  for input the action itself does not take.

  Those are the only two that reach it. Every operation names its refusal as
  an atom and raises nothing it keeps. A policy never refuses where this is
  asked: the page reads the terms, which anyone may, and its panel always
  calls as a person; the HTTP routes are not there while Earn is off
  (`AutolaunchWeb.Router.admit_earn/2`), every caller of the private ones is
  the actor its policy admits (the person on their own route, a paired agent
  on the agent routes), and the steps route is refused before the router in
  prelaunch read-only mode (`AutolaunchWeb.Prelaunch`), both set when the site
  starts; the hosted MCP tools put their own errors into words.
  """
  def reason(%Ash.Error.Unknown{errors: [%Autolaunch.Earn.Refused{reason: reason}]}), do: reason
  def reason(%Ash.Error.Invalid{}), do: :invalid_request

  # The hosted MCP tools: the four operations every agent surface runs, each with
  # its browser tool's title, listed and run only as their policies allow (only
  # while the site offers Earn, and never by a connected app calling as itself).
  tools do
    tool :earn_products, Autolaunch.Earn.Product, :products_answer do
      title("List the places to earn on USDC")

      description "List every place Autolaunch offers to lend USDC on Base, each read from its market at a recent block, shared for up to ten seconds: its id, protocol, market and asset with the exact addresses of its pool, asset and market token; rate_now, the market's yearly rate at today's rate, before compounding (yearly_percent, cut to two decimals, and ray, the market's own figure in units of 10^27), which changes as borrowing changes; supplied, what is lent in all; available, what can be withdrawn right now; supply_cap in whole tokens and capacity, the most one deposit can be before that cap (both null when it has none; capacity 0 when it is full); status (open, frozen: withdrawals only, paused: nothing moves, or inactive); the block the figures were read at; and the risks in plain words. Every amount is in the asset's smallest units (USDC has 6 decimals). Reads only."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :earn_quote, Autolaunch.Earn.Product, :quote_answer do
      title("Preview an Earn deposit or withdrawal")

      description "Preview a deposit or withdrawal on one Earn product for one of my person's own wallets, at the latest block, without its wallet calls: the amount it moves (for everything, the balance at this block; a little more interest lands with it), whether the wallet's USDC approval to the market already covers a deposit (approved; otherwise the steps begin with an exact approval), what would block it (blocked: market_inactive, market_paused, market_frozen, not_enough_usdc, over_supply_cap, over_balance or not_available_now, in code and words, the first that applies in that order of market, wallet, then the market's capacity or what is available), the wallet's balance in the market, its USDC and its allowance, and the block it was read at. A preview reserves nothing; the chain may change before a step is sent. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :earn_positions, Autolaunch.Earn.Product, :positions_answer do
      title("Read my Earn balances")

      description "Read my person's balance in every Earn product, for the wallet they signed in with, at the latest block: for each product its balance in the market, interest included (position none or held), the wallet's own USDC and its allowance to the market, and the block it was read at. Every amount is in the asset's smallest units. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :prepare_earn, Autolaunch.Earn.Product, :prepare_answer do
      title("Prepare an Earn step")

      description "Prepare the wallet steps for a deposit or withdrawal on one Earn product, for one of my person's own wallets: a deposit is an exact USDC approval to the market's pool (usdc_approval) then supply, crediting the wallet; a withdrawal is withdraw, sending the USDC to the wallet, with everything taking the whole balance as it stands when the step lands. Each step is to, data and value for the wallet to send in turn, its data ending with the site's Builder Code. The answer carries what the preview does (amount, approved, blocked, the wallet's figures and the block): blocked names a reason the chain's state at that block makes the step certain to fail, and the steps are still returned. Built from block N, a step may be stale by the time it is sent. The site only prepares: the wallet's own key signs and sends each step, and money moves only then. Changes nothing."

      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end
  end

  # The four operations every agent surface runs, by the names the hosted MCP
  # tools carry, then the readings the page draws from.
  resources do
    resource Autolaunch.Earn.Product do
      define :earn_products, action: :products_answer
      define :earn_quote, action: :quote_answer, args: [:product, :kind]
      define :earn_positions, action: :positions_answer
      define :prepare_earn, action: :prepare_answer, args: [:product, :kind]
      define :read_earn_terms, action: :terms, args: [:product]
      define :read_earn_position, action: :position, args: [:product]
      define :prepare_earn_steps, action: :prepare, args: [:product, :kind]
    end
  end
end
