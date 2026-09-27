defmodule Autolaunch.Stocks.LabProjection do
  @moduledoc """
  Projects verified Base Memestake launches into `Auction` rows.

  The row identity is the chain and auction address, exactly as for Agent
  launches, so the creator's own confirmation and launch discovery recovering
  the same launch are one row, written once by whichever comes first.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction
  @actor %System{}

  @doc """
  Projects one receipt-verified Stocks launch from its operation, once: when
  its auction row already exists, a second confirmation changes nothing, so it
  can never take that auction back to how it started.

  It runs inside the caller's transaction (the creator's page, or launch
  discovery), so nothing is announced here: it returns the listing
  notifications of the row it wrote, for the caller to send once that
  transaction has committed. A launch already stored returns none.
  """
  def project_launch(%{review: review} = operation, result) when is_map(result) do
    %{"chain" => %{"chain_id" => chain_id}, "signer" => signer, "facts" => facts} = review

    %{
      kind: :stocks,
      featured: false,
      current_clearing_price: "0",
      chain_id: chain_id,
      auction_address: result["auction"],
      origin: :site,
      creator_human_account_id: operation.human_account_id,
      creator_address: String.downcase(signer),
      title: facts["name"],
      summary: facts["description"],
      token_symbol: facts["symbol"],
      website: facts["website"],
      telegram: facts["telegram"],
      image: facts["image"],
      quote_token_address: facts["stock"],
      quote_token_symbol: facts["stock_symbol"],
      quote_token_decimals: String.to_integer(facts["stock_decimals"]),
      required_currency_raised: facts["required_stock_raised"],
      state: :created,
      # The auction's funds recipient: every raised STOCK goes to the launchpad,
      # which is the only custody a Stocks launch has.
      treasury_address: facts["launchpad"]
    }
    |> Autolaunch.record_launch_auction(actor: @actor, return_notifications?: true)
    |> case do
      {:ok, %Auction{__metadata__: %{upsert_skipped: true}}, _notifications} -> {:ok, []}
      {:ok, _auction, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, error}
    end
  end
end
