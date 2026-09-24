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

  It runs inside the caller's transaction (the creator's session, or launch
  discovery), so nothing is announced here: it returns the listing
  notifications of the row it wrote, for the caller to send once that
  transaction has committed. A launch already stored returns none.
  """
  def project_launch(
        %{envelope: %{"chain_id" => chain_id, "metadata" => %{"lab" => lab}} = envelope} =
          operation,
        result
      )
      when is_integer(chain_id) and is_map(lab) and is_map(result) do
    arguments = envelope["arguments"]

    %{
      kind: :stocks,
      featured: false,
      current_clearing_price: "0",
      chain_id: chain_id,
      auction_address: result["auction"],
      origin: :site,
      creator_human_account_id: Map.get(operation, :human_account_id),
      creator_address: String.downcase(envelope["expected_signer"]),
      title: arguments["name"],
      summary: arguments["description"],
      token_symbol: arguments["symbol"],
      website: arguments["website"],
      image: arguments["image"],
      quote_token_address: arguments["stock"],
      quote_token_symbol: arguments["stock_symbol"],
      quote_token_decimals: String.to_integer(arguments["stock_decimals"]),
      required_currency_raised: arguments["required_stock_raised"],
      state: :created,
      # The auction's funds recipient: every raised STOCK goes to the launchpad,
      # which is the only custody a Stocks launch has.
      treasury_address: arguments["launchpad"]
    }
    |> Autolaunch.record_launch_auction(actor: @actor, return_notifications?: true)
    |> case do
      {:ok, %Auction{__metadata__: %{upsert_skipped: true}}, _notifications} -> {:ok, []}
      {:ok, _auction, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, error}
    end
  end

  def project_launch(_operation, _result), do: {:ok, []}
end
