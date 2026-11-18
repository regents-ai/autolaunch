defmodule Autolaunch.AgentRobinhoodBid do
  @moduledoc """
  A paired agent's wallet steps for its person's bids on Robinhood Chain
  auctions, offered only while the site switches them on
  (`AUTOLAUNCH_AGENT_ROBINHOOD_BIDS=true`, `enabled?/0`):

    * `:prepare` — one USDG bid's steps, reviewed as the auction page reviews
      them (`Autolaunch.Robinhood.StockBidActions.review/2`)
    * `:settle` — the return and claim of one of the person's own bids,
      reviewed as the bid's row reviews them
      (`Autolaunch.Robinhood.StockBidSettlementActions.review/3`)

  Every agent surface runs these two, so each answers in one shape: the signed
  HTTP routes, which the browser tools call
  (`AutolaunchWeb.AgentRobinhoodBidController`), and the hosted MCP tools. The
  person must have a verified wallet now, as `autolaunch_my_positions` asks, so
  their own bids are read as theirs, and the wallet is one of the person's own,
  `signer` when named, otherwise the wallet they signed in with
  (`Autolaunch.CoveredCalls.Signer.verified/1` and `wallet/2`, from one read of
  the account).

  The auction is one the site lists on Robinhood Chain, as its pages show it. A
  Robinhood bid is not stored here: it is named by its auction's address and
  the auction's number for it, as `autolaunch_my_positions` gives it, and a bid
  settled is one a wallet of the person's placed, by the auction's own record,
  on an auction the site lists, hidden or not, as on the bid's page. A bid on
  an auction whose bidding has ended, by its record or the clock the auction
  keeps at the latest block, is refused as `bidding_ended`, and one while even
  that clock's next step is before the auction's start block as
  `auction_not_started`: the auction is certain to refuse either.

  A refusal is an `Autolaunch.AgentRobinhoodBid.Refused` holding one of the
  codes the Robinhood bid contract documents (`code/1`). Anything the review
  returns or raises that is not a reason it names is logged by kind alone and
  answered `bid_unavailable`.

  The site only prepares: the wallet's own key signs and sends each step on
  Robinhood Chain, and nothing is stored.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.AgentRobinhoodBid.Refused
  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Robinhood.{Lab, StockBidActions, StockBidSettlementActions}
  alias AutolaunchWeb.ReadFailure

  # Every reason the two reviews, the auction's listing, the wallet and the
  # person's account name, as the code an agent is answered with. A refusal the
  # auction page or the bid's row names keeps its own name where the page gives
  # it one. An id naming no auction the site lists on Robinhood Chain names no
  # auction here. A bid id naming no bid, or a bid on no auction listed here,
  # is none of the person's, as another's bid is. Robinhood Chain answering
  # what is not a block of it, or not at all, could not be read just now, and
  # so could a stock's decimals outside what a token can have, which only the
  # chain names. A deployment description that does not load or no longer
  # matches the chain, an auction address the site stored that is not one or
  # holds no contract, and a listed auction no launchpad of the deployment
  # made (`unknown_auction` on a bid, `auction_not_found` on a settlement), are
  # the site's own fault.
  @codes %{
    authentication_required: :authentication_required,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    auction_not_listed: :auction_not_found,
    invalid_slippage: :invalid_slippage,
    invalid_decimal: :invalid_decimal,
    amount_required: :invalid_amount,
    amount_not_representable: :invalid_amount,
    max_price_required: :invalid_price,
    price_out_of_range: :invalid_price,
    price_below_admissible_tick: :price_below_admissible_tick,
    bidding_ended: :bidding_ended,
    bid_preparation_unavailable: :bid_preparation_unavailable,
    amount_above_balance: :amount_above_balance,
    usdg_route_unavailable: :usdg_route_unavailable,
    stock_route_unavailable: :usdg_route_unavailable,
    quote_out_of_range: :usdg_route_unavailable,
    stock_not_listed: :stock_not_listed,
    not_your_bid: :not_your_bid,
    bid_not_found: :not_your_bid,
    auction_not_started: :auction_not_started,
    auction_not_ended: :auction_not_ended,
    already_exited: :already_exited,
    claim_not_open: :claim_not_open,
    nothing_to_claim: :nothing_to_claim,
    bid_not_exited: :bid_not_exited,
    failed_bid_returned: :failed_bid_returned,
    settlement_reverted: :settlement_reverted,
    # The auction refusing a claim as it would an exit it cannot take.
    bid_needs_partial_exit: :settlement_reverted,
    bid_needs_partial_exit_hints_unavailable: :bid_needs_partial_exit_hints_unavailable,
    price_history_long: :price_history_long,
    chain_unavailable: :chain_unavailable,
    invalid_chain_response: :chain_unavailable,
    invalid_block_header: :chain_unavailable,
    wrong_chain: :chain_unavailable,
    invalid_decimals: :chain_unavailable,
    robinhood_unavailable: :bid_unavailable,
    lab_config_changed: :bid_unavailable,
    invalid_auction: :bid_unavailable,
    lab_contract_missing: :bid_unavailable,
    unknown_auction: :bid_unavailable,
    auction_not_found: :bid_unavailable
  }

  # Typed figures reach the review exactly as sent, so its own refusals name
  # what is wrong with them, as on the page.
  @typed [allow_empty?: true, trim?: false]

  # A Robinhood bid's id as `autolaunch_my_positions` gives it: the auction's
  # address and the auction's number for the bid, at most the 78 digits of the
  # largest number the auction can hold (`@max_bid_number`).
  @bid_id ~r/\A0x[0-9a-f]{40}:(0|[1-9][0-9]{0,77})\z/
  @max_bid_number Integer.pow(2, 256) - 1

  # What each input of the hosted tools is, in the browser tools' words
  # (priv/agent_robinhood_bids_tools.json).
  @auction_id "The auction's id exactly as autolaunch_auctions lists it, for a Robinhood Chain auction."
  @usdg_amount "The total to bid in USDG, as a decimal with at most 6 decimal places. The bid converts it into the auction's stock and returns what is left over."
  @max_price "The most to pay per token, as a decimal in the auction's stock. It is lowered to the auction's price grid."
  @slippage "The most the stock bought may fall short of the route's estimate, in percent from 0 to 99.99 with at most two decimal places. 5 when left out."
  @bid "The bid's id exactly as autolaunch_my_positions gives it (bid), for a bid on Robinhood Chain."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @doc "Whether the site offers agent Robinhood bids (`AUTOLAUNCH_AGENT_ROBINHOOD_BIDS=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_robinhood_bids, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason either review, the
  auction's listing, the wallet or the person's account names. Any other
  reason, and anything that is not a reason, is `:bid_unavailable`: a read
  that failed, or one nobody expected.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)
  def code(_unexpected), do: :bid_unavailable

  actions do
    action :prepare, :map do
      description "One USDG bid's wallet steps on a Robinhood Chain auction, for a wallet of the paired agent's person."

      argument :auction_id, :uuid, allow_nil?: false, description: @auction_id

      argument :usdg_amount, :string,
        allow_nil?: false,
        constraints: @typed,
        description: @usdg_amount

      argument :max_price, :string,
        allow_nil?: false,
        constraints: @typed,
        description: @max_price

      argument :slippage_percent, :string, constraints: @typed, description: @slippage
      argument :signer, :string, description: @signer

      run fn input, %{actor: actor} -> __MODULE__.bid_steps(input.arguments, actor) end
    end

    action :settle, :map do
      description "The return and claim of one of the paired agent's person's own bids on a Robinhood Chain auction."

      argument :bid, :string,
        allow_nil?: false,
        constraints: [trim?: false, match: @bid_id],
        description: @bid

      argument :signer, :string, description: @signer

      run fn input, %{actor: actor} -> __MODULE__.settlement_steps(input.arguments, actor) end
    end
  end

  @doc false
  def bid_steps(arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, auction} <- listed_auction(arguments.auction_id),
         :ok <- open(auction),
         {:ok, reviewed} <- StockBidActions.review(request(arguments, auction), signer),
         :ok <- open(reviewed) do
      {:ok,
       %{
         kind: "bid",
         signer: signer,
         auction: %{id: auction.id, address: auction.auction_address},
         chain: reviewed.chain,
         block: reviewed.block,
         steps: reviewed.steps,
         approved: not Enum.any?(reviewed.steps, &(&1.step == "usdg_approval")),
         facts: reviewed.facts
       }}
    end
    |> refused()
  rescue
    failure -> refused({:error, failure})
  end

  @doc false
  def settlement_steps(%{bid: bid} = arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, auction, number} <- listed_bid(bid),
         {:ok, reviewed} <-
           StockBidSettlementActions.review(
             %{auction: auction.auction_address, bid_id: number},
             signer,
             account.wallet_addresses
           ) do
      {:ok,
       %{
         kind: "settle",
         signer: signer,
         bid: bid,
         auction: %{id: auction.id, address: auction.auction_address},
         chain: reviewed.chain,
         block: reviewed.block,
         steps: reviewed.steps,
         facts: reviewed.facts
       }}
    end
    |> refused()
  rescue
    failure -> refused({:error, failure})
  end

  # A Robinhood Chain auction the site lists and shows, as its page reads it;
  # an id naming any other auction names none here.
  defp listed_auction(id) do
    case Autolaunch.get_listed_auction(id, actor: nil) do
      {:ok, %Autolaunch.Auction{chain_id: chain_id} = auction} ->
        if Lab.chain?(chain_id), do: {:ok, auction}, else: {:error, :auction_not_listed}

      {:ok, nil} ->
        {:error, :auction_not_listed}

      {:error, error} ->
        {:error, error}
    end
  end

  # A Robinhood bid's auction must be one the site lists on Robinhood Chain,
  # hidden or not, as on the bid's page, and its number one the auction can
  # hold; any other bid is none of the person's here, known before anything is
  # read.
  defp listed_bid(bid) do
    [address, number] = String.split(bid, ":")

    with true <- String.to_integer(number) <= @max_bid_number || {:error, :not_your_bid},
         {:ok, %Autolaunch.Auction{} = auction} <-
           Autolaunch.get_held_robinhood_auction(address, actor: %Autolaunch.Actors.System{}) do
      {:ok, auction, number}
    else
      {:ok, nil} -> {:error, :not_your_bid}
      {:error, error} -> {:error, error}
    end
  end

  # The review's request: the auction's own address and the figures as typed.
  # A slippage left out is the page's own starting one.
  defp request(arguments, auction) do
    arguments
    |> Map.take([:usdg_amount, :max_price, :slippage_percent])
    |> Map.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.put(:auction, auction.auction_address)
  end

  # Bidding has ended once the auction's record says so, before Robinhood
  # Chain is asked anything; the page offers no bid then either. Otherwise the
  # review's clock decides: while even its next step is before the start
  # block bidding has not started, and from the end block it has ended.
  defp open(%Autolaunch.Auction{state: state}) when state in [:ended, :graduated, :failed],
    do: {:error, :bidding_ended}

  defp open(%Autolaunch.Auction{}), do: :ok
  defp open(%{blocked: nil}), do: :ok
  defp open(%{blocked: reason}), do: {:error, reason}

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentRobinhoodBidAnswer`). One
  # nobody named is logged by kind alone (`AutolaunchWeb.ReadFailure`).
  defp refused({:ok, _answer} = answered), do: answered

  defp refused({:error, %Ash.Error.Invalid.Unavailable{reason: reason}}),
    do: refused({:error, reason})

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :bid_unavailable, do: ReadFailure.log("agent robinhood bid", reason)
    {:error, Refused.exception(reason: code)}
  end

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent Robinhood bids: off, the hosted MCP server neither lists nor
    # runs either tool, as the routes and browser tools are not there either.
    policy always() do
      forbid_unless Autolaunch.AgentRobinhoodBid.Checks.Offered
      authorize_if actor_attribute_equals(:role, :agent)
    end

    # Wallet steps wait for the site to leave prelaunch read-only mode, as the
    # HTTP routes do (`AutolaunchWeb.Prelaunch`).
    policy always() do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
