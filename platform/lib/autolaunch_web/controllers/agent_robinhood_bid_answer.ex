defmodule AutolaunchWeb.AgentRobinhoodBidAnswer do
  @moduledoc """
  The agent Robinhood bid answers both HTTP routes give
  (`AutolaunchWeb.AgentRobinhoodBidController`): the answer the operation built
  (`Autolaunch.AgentRobinhoodBid`) as `data`, or its refusal with its status
  and words. The hosted MCP tools give the same refusals in the same words
  (`body/1`, through `AutolaunchWeb.ToolErrors`).

  Every refusal is one of the codes `Autolaunch.AgentRobinhoodBid.code/1`
  gives, each with its own status and words for an agent here.
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.AgentRobinhoodBid.Refused
  alias AutolaunchWeb.{ApiError, ReadFailure}

  @refusals %{
    invalid_request:
      {:unprocessable_entity,
       "Send only the documented fields, each as text: auction_id, usdg_amount, max_price, slippage_percent and signer for a bid; signer for a bid's settlement."},
    authentication_required:
      {:unauthorized, "Your person's Regent account could not be read; nothing was prepared."},
    wrong_signer: {:forbidden, "That wallet is not one of your person's own wallets."},
    wallet_required:
      {:conflict,
       "Your person's Regent account has no verified wallet to act with, or signer is not a wallet address."},
    auction_not_found:
      {:not_found, "There is no Robinhood Chain auction taking bids here with that id."},
    invalid_amount:
      {:unprocessable_entity,
       "Send usdg_amount as a decimal above zero with at most 6 decimal places."},
    invalid_decimal:
      {:unprocessable_entity, "Send usdg_amount and max_price as plain decimals above zero."},
    invalid_price:
      {:unprocessable_entity, "Send a max_price above zero that the auction can hold."},
    invalid_slippage:
      {:unprocessable_entity,
       "Send slippage_percent from 0 to 99.99, with at most two decimal places."},
    price_below_admissible_tick:
      {:unprocessable_entity,
       "That max_price does not reach an allowed price above the auction's clearing price."},
    bidding_ended:
      {:conflict, "Bidding has ended on this auction, so the auction would refuse this bid."},
    bid_preparation_unavailable:
      {:conflict,
       "No bid at that max_price can be placed on this auction now. Set it above the auction's current price."},
    amount_above_balance: {:conflict, "This wallet holds less USDG than that."},
    usdg_route_unavailable:
      {:conflict, "USDG cannot be converted for this auction right now. Try a different amount."},
    stock_not_listed:
      {:conflict, "This auction's stock is not one this site lists, so nothing is prepared."},
    not_your_bid:
      {:not_found,
       "None of your person's wallets holds a bid with that id on a Robinhood Chain auction listed here."},
    auction_not_started: {:conflict, "Bidding has not started on this auction."},
    auction_not_ended: {:conflict, "This bid stays in the auction until bidding ends."},
    already_exited: {:conflict, "This bid has already been returned."},
    claim_not_open: {:conflict, "Tokens cannot be claimed yet."},
    nothing_to_claim: {:conflict, "This bid has no tokens to claim."},
    bid_not_exited: {:conflict, "Return this bid before claiming its tokens."},
    failed_bid_returned:
      {:conflict,
       "This bid was returned in full: the launch did not raise enough, and there are no tokens to claim."},
    settlement_reverted: {:conflict, "The auction refused this right now."},
    bid_needs_partial_exit_hints_unavailable:
      {:service_unavailable,
       "This bid was only partly filled and the auction's records for it could not be traced. Try again in a moment."},
    price_history_long:
      {:service_unavailable,
       "This auction's price history is long, and only part of it could be read just now. Try again to read on."},
    chain_unavailable:
      {:service_unavailable, "Robinhood Chain could not be read just now. Try again in a moment."},
    bid_unavailable: {:service_unavailable, "That did not go through. Try again in a moment."}
  }

  @fields %{
    prepare: ~w(auction_id usdg_amount max_price slippage_percent signer),
    settle: ~w(signer)
  }

  @doc "Answers with the operation's answer, or with the refusal it carries."
  def send(conn, {:ok, answer}), do: json(conn, %{data: answer})
  def send(conn, {:error, error}), do: refuse(conn, reason(error))

  @doc "Answers with the refusal named `reason`."
  def refuse(conn, reason) do
    {status, code, message} = refusal(reason)
    ApiError.send(conn, status, code, message)
  end

  @doc "The error document of the refusal named `reason`, as the routes send it."
  def body(reason) do
    {_status, code, message} = refusal(reason)
    ApiError.body(code, message)
  end

  @doc """
  A route's body as the operation's input, or `:error` when it names a field
  the operation does not take or gives one as anything but text.
  """
  def input(operation, body) do
    if Enum.all?(body, fn {key, value} -> key in @fields[operation] and is_binary(value) end),
      do: {:ok, body},
      else: :error
  end

  # The refusal an operation answered with: the code it named, or
  # `:invalid_request` for input the action itself does not take. A policy does
  # not refuse here: every caller of the routes is a paired agent, the routes
  # are not there while agent Robinhood bids are off
  # (`AutolaunchWeb.Router.admit_agent_robinhood_bids/2`), and both are refused
  # before the router in prelaunch read-only mode (`AutolaunchWeb.Prelaunch`).
  # Anything else is logged by kind alone and answered `bid_unavailable`.
  defp reason(%Ash.Error.Unknown{errors: [%Refused{reason: reason}]}), do: reason
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request

  defp reason(unexpected) do
    ReadFailure.log("agent robinhood bid", unexpected)
    :bid_unavailable
  end

  defp refusal(reason) do
    {status, message} = Map.fetch!(@refusals, reason)
    {status, Atom.to_string(reason), message}
  end
end
