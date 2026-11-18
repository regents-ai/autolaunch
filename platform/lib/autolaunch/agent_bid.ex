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
  and the hosted MCP tools. The person must have a verified wallet now, as
  `autolaunch_my_positions` asks, so their own bids are read as theirs, and the
  wallet is one of the person's own, `signer` when named, otherwise the wallet
  they signed in with (`Autolaunch.CoveredCalls.Signer.verified/1` and
  `wallet/2`, from one read of the account), and a bid
  settled is one a wallet of theirs holds (`Autolaunch.Bid`'s `:agent_by_bid_id`).
  Once the latest block has reached the auction's end block, as the auction
  itself reads it, a bid is refused as `bidding_ended`: the auction would
  refuse it.

  A refusal is an `Autolaunch.AgentBid.Refused` holding one of the codes the
  agent bid contract documents (`code/1`). Anything the review returns that is
  not a reason it names is logged and answered `bid_unavailable`.

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
  alias AutolaunchWeb.ReadFailure

  @approvals ["token_approval", "permit2_approval", "usdc_approval"]

  # Every reason the two reviews, the wallet and the person's account name, as
  # the code an agent is answered with. A refusal the auction page or the bid
  # card names keeps its own name. A treasury that is not verified is not open
  # yet; one whose verified state or evidence no longer holds is paused while it
  # is checked. Base answering what is not a block of Base, or not at all, could
  # not be read just now. An auction address the site stored that is not one, or
  # that holds no contract, is the site's own fault.
  @codes %{
    authentication_required: :authentication_required,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    auction_not_found: :auction_not_found,
    invalid_amount: :invalid_amount,
    invalid_decimal: :invalid_decimal,
    invalid_price: :invalid_price,
    invalid_slippage: :invalid_slippage,
    price_below_admissible_tick: :price_below_admissible_tick,
    bidding_ended: :bidding_ended,
    bid_preparation_unavailable: :bid_preparation_unavailable,
    auction_currency_changed: :auction_currency_changed,
    amount_above_balance: :amount_above_balance,
    usdc_bids_unavailable: :usdc_bids_unavailable,
    stock_not_admitted: :stock_not_admitted,
    usdc_route_unavailable: :usdc_route_unavailable,
    not_your_bid: :not_your_bid,
    position_not_on_chain: :position_not_on_chain,
    bid_not_found: :bid_not_found,
    auction_not_started: :auction_not_started,
    auction_not_ended: :auction_not_ended,
    already_exited: :already_exited,
    claim_not_open: :claim_not_open,
    nothing_to_claim: :nothing_to_claim,
    bid_not_exited: :bid_not_exited,
    settlement_reverted: :settlement_reverted,
    # The auction refusing a claim as it would an exit it cannot take.
    bid_needs_partial_exit: :settlement_reverted,
    bid_needs_partial_exit_hints_unavailable: :bid_needs_partial_exit_hints_unavailable,
    price_history_long: :price_history_long,
    treasury_report_missing: :treasury_report_missing,
    treasury_not_verified: :treasury_report_missing,
    treasury_security_changed: :treasury_security_changed,
    treasury_source_reorged: :treasury_security_changed,
    treasury_safe_evidence_mismatch: :treasury_security_changed,
    treasury_evidence_invalid: :treasury_security_changed,
    treasury_evidence_hash_invalid: :treasury_security_changed,
    treasury_transfer_evidence_invalid: :treasury_security_changed,
    treasury_execution_evidence_invalid: :treasury_security_changed,
    treasury_execution_input_invalid: :treasury_security_changed,
    treasury_module_pagination_cycle: :treasury_security_changed,
    treasury_configuration_drift: :treasury_configuration_drift,
    chain_unavailable: :chain_unavailable,
    invalid_chain_response: :chain_unavailable,
    invalid_block_header: :chain_unavailable,
    transaction_missing: :chain_unavailable,
    wrong_chain: :chain_unavailable,
    treasury_observation_incomplete: :chain_unavailable,
    treasury_module_pagination_incomplete: :chain_unavailable,
    invalid_address: :bid_unavailable,
    lab_contract_missing: :bid_unavailable
  }

  # Typed figures reach the review exactly as sent, so its own refusals name
  # what is wrong with them, as on the page.
  @typed [allow_empty?: true, trim?: false]

  # What each input of the hosted tools is, in the browser tools' words
  # (priv/agent_bids_tools.json).
  @auction_id "The auction's id exactly as autolaunch_auctions lists it, for a Base auction."
  @amount "The total to bid, as a decimal in the currency paid, with at most as many decimal places as that currency has: the auction's own (its quote_token.decimals in autolaunch_auction) or, with pay_with USDC, USDC (6 decimals)."
  @max_price "The most to pay per token, as a decimal in the auction's own currency. It is lowered to the auction's price grid."
  @pay_with "USDC to pay in USDC on a Memestock auction that takes it; leave it out to pay in the auction's own currency."
  @slippage "For a USDC bid, the most the stock bought may fall short of the route's estimate, in percent from 0 to 99.99 with at most two decimal places. 5 when left out."
  @bid "The bid's id exactly as autolaunch_my_positions gives it (bid), for a bid on Base."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @doc "Whether the site offers agent bids (`AUTOLAUNCH_AGENT_BIDS=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_bids, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason either review, the
  wallet or the person's account names. Any other reason, and anything that is
  not a reason, is `:bid_unavailable`: a deployment description that does not
  load (its faults include the file system's own), or a read that failed.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)
  def code(_unexpected), do: :bid_unavailable

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
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, reviewed} <- BidActions.review(request(arguments), signer),
         :ok <- open(reviewed) do
      {:ok,
       %{
         kind: "bid",
         signer: signer,
         auction: %{id: reviewed.context.auction_id, address: reviewed.context.auction_address},
         chain: reviewed.chain,
         block: reviewed.block,
         steps: reviewed.steps,
         approved: not Enum.any?(reviewed.steps, &(&1.step in @approvals)),
         facts: reviewed.facts
       }}
    end
    |> refused()
  end

  @doc false
  def settlement_steps(%{bid: bid} = arguments, context) do
    with {:ok, account} <- Signer.verified(context.actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
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

  # The page still shows a review once bidding has ended; an agent is refused.
  defp open(%{blocked: nil}), do: :ok
  defp open(%{blocked: :bidding_ended}), do: {:error, :bidding_ended}

  # A bid none of the person's wallets holds is not theirs to settle, whether
  # it is another's or none at all.
  defp own_bid(bid, context) do
    case Autolaunch.get_agent_bid_position(bid, Ash.Context.to_opts(context)) do
      {:ok, %Autolaunch.Bid{} = position} -> {:ok, position}
      {:ok, nil} -> {:error, :not_your_bid}
      {:error, error} -> {:error, error}
    end
  end

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentBidAnswer`). One nobody named
  # is logged by kind alone (`AutolaunchWeb.ReadFailure`).
  defp refused({:ok, _answer} = answered), do: answered

  defp refused({:error, %Ash.Error.Invalid.Unavailable{reason: reason}}),
    do: refused({:error, reason})

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :bid_unavailable, do: ReadFailure.log("agent bid", reason)
    {:error, Refused.exception(reason: code)}
  end

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
