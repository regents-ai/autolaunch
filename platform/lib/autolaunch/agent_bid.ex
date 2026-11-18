defmodule Autolaunch.AgentBid do
  @moduledoc """
  A paired agent's wallet steps for its person's bids on Base auctions, offered
  only while the site switches them on (`AUTOLAUNCH_AGENT_BIDS=true`,
  `enabled?/0`):

    * `:prepare` — one bid's steps, reviewed as the auction page reviews them
      (`Autolaunch.BidActions.review/2`)
    * `:settle` — the return and claim of one of the person's own bids,
      reviewed as the bid's card reviews them
      (`Autolaunch.BidSettlementActions.review/2`)

  Every agent surface runs these two, so each answers in one shape: the signed
  HTTP routes, which the browser tools call (`AutolaunchWeb.AgentBidController`),
  and the hosted MCP tools. The wallet is one of the person's own
  (`Autolaunch.CoveredCalls.Signer`): `signer` when named, otherwise the wallet
  they signed in with, and a bid settled is one a wallet of theirs holds
  (`Autolaunch.Bid`'s `:agent_by_bid_id`). A refusal is an
  `Autolaunch.AgentBid.Refused` naming the page's own reason. A bid whose
  auction has ended bidding by its record or the latest block is answered with
  `blocked`, beside its steps, as the page no longer offers its form then.

  The site only prepares: the wallet's own key signs and sends each step, and
  nothing is stored. The auction's reader records a bid the auction announces
  as its bidder's position, as it records every bid
  (`Autolaunch.AuctionActivity`).
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.AgentBid.Refused
  alias Autolaunch.{BidActions, BidIdentity, BidSettlementActions}
  alias Autolaunch.CoveredCalls.Signer

  @approvals ["token_approval", "permit2_approval", "usdc_approval"]

  @bidding_ended "Bidding has ended on this auction, so the auction would refuse this bid."

  # Typed figures reach the review exactly as sent, so its own refusals name
  # what is wrong with them, as on the page.
  @typed [allow_empty?: true, trim?: false]

  # What each input of the hosted tools is, in the browser tools' words
  # (priv/agent_bids_tools.json).
  @auction_id "The auction's id exactly as autolaunch_auctions lists it, for a Base auction."
  @amount "The total to bid, as a decimal in the currency paid: the auction's own (18 decimals) or, with pay_with USDC, USDC (6 decimals)."
  @max_price "The most to pay per token, as a decimal in the auction's own currency. It is lowered to the auction's price grid."
  @pay_with "USDC to pay in USDC on a Memestock auction that takes it; leave it out to pay in the auction's own currency."
  @slippage "For a USDC bid, the most the stock bought may fall short of the route's estimate, in percent from 0 to 99.99 with at most two decimal places. 5 when left out."
  @bid "The bid's id exactly as autolaunch_my_positions gives it (bid), for a bid on Base."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @doc "Whether the site offers agent bids (`AUTOLAUNCH_AGENT_BIDS=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_bids, :off) == :on

  actions do
    action :prepare, :map do
      description "One bid's wallet steps on a Base auction, for a wallet of the paired agent's person."

      argument :auction_id, :uuid, allow_nil?: false, description: @auction_id

      argument :amount, :string,
        allow_nil?: false,
        constraints: @typed,
        description: @amount

      argument :max_price, :string,
        allow_nil?: false,
        constraints: @typed,
        description: @max_price

      argument :pay_with, :atom, constraints: [one_of: [:USDC]], description: @pay_with
      argument :slippage_percent, :string, constraints: @typed, description: @slippage
      argument :signer, :string, description: @signer

      run fn input, %{actor: actor} -> __MODULE__.bid_steps(input.arguments, actor) end
    end

    action :settle, :map do
      description "The return and claim of one of the paired agent's person's own bids on a Base auction."

      argument :bid, :string,
        allow_nil?: false,
        constraints: BidIdentity.constraints(),
        description: @bid

      argument :signer, :string, description: @signer

      run fn input, context -> __MODULE__.settlement_steps(input.arguments, context) end
    end
  end

  @doc false
  def bid_steps(arguments, actor) do
    with {:ok, signer} <- Signer.wallet(actor, arguments[:signer]),
         {:ok, reviewed} <- BidActions.review(request(arguments), signer) do
      {:ok,
       %{
         kind: "bid",
         signer: signer,
         auction: %{id: reviewed.context.auction_id, address: reviewed.context.auction_address},
         chain: reviewed.chain,
         block: reviewed.block,
         steps: reviewed.steps,
         approved: not Enum.any?(reviewed.steps, &(&1.step in @approvals)),
         blocked: blocked(reviewed.blocked),
         facts: reviewed.facts
       }}
    end
    |> refused()
  end

  @doc false
  def settlement_steps(%{bid: bid} = arguments, context) do
    with {:ok, signer} <- Signer.wallet(context.actor, arguments[:signer]),
         {:ok, position} <- own_bid(bid, context),
         {:ok, reviewed} <- BidSettlementActions.review(position, signer) do
      {:ok,
       %{
         kind: "settle",
         signer: signer,
         bid: position.bid_id,
         auction: %{id: position.auction_id, address: reviewed.context.auction_address},
         chain: reviewed.chain,
         block: reviewed.block,
         steps: reviewed.steps,
         approved: true,
         blocked: nil,
         facts: reviewed.facts
       }}
    end
    |> refused()
  end

  # The review's request: the figures as typed, and the currency paid as the
  # page names it. A slippage left out is the page's own starting one.
  defp request(arguments) do
    arguments
    |> Map.take([:auction_id, :amount, :max_price, :slippage_percent])
    |> Map.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.put(:pay_with, arguments[:pay_with] && Atom.to_string(arguments.pay_with))
  end

  # A bid none of the person's wallets holds is not theirs to settle, whether
  # it is another's or none at all.
  defp own_bid(bid, context) do
    opts = Keyword.put(Ash.Context.to_opts(context), :not_found_error?, false)

    case Autolaunch.get_agent_bid_position(bid, opts) do
      {:ok, %Autolaunch.Bid{} = position} -> {:ok, position}
      _not_theirs -> {:error, :not_your_bid}
    end
  end

  defp blocked(nil), do: nil
  defp blocked(:bidding_ended), do: %{code: :bidding_ended, message: @bidding_ended}

  # A refusal keeps the reason it names, which Ash would otherwise turn into text
  # (`AutolaunchWeb.AgentBidAnswer.reason/1`).
  defp refused({:error, %Ash.Error.Invalid.Unavailable{reason: reason}}),
    do: {:error, Refused.exception(reason: reason)}

  defp refused({:error, reason}) when is_atom(reason),
    do: {:error, Refused.exception(reason: reason)}

  defp refused(result), do: result

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent bids: off, the hosted MCP server neither lists nor runs
    # either tool, as the routes and browser tools are not there either.
    policy always() do
      forbid_unless Autolaunch.AgentBid.Checks.Offered
      authorize_if actor_attribute_equals(:role, :agent)
    end

    # Wallet steps wait for the site to leave prelaunch read-only mode, as the
    # HTTP routes do (`AutolaunchWeb.Prelaunch`).
    policy always() do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
