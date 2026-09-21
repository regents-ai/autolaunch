defmodule Autolaunch.Stocks.LabProjection do
  @moduledoc """
  Projects verified local Stocks launches into `Auction` rows.

  The row identity is the chain and auction address, exactly as for Agent
  launches, so a launch the creator's own verification projected and the same
  launch the market feed later reads from the launchpad's logs are one row.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction
  @actor %System{}
  @domain Autolaunch

  @doc "Projects one receipt-verified Stocks launch from its operation."
  def project_launch(
        %{envelope: %{"chain_id" => chain_id, "metadata" => %{"lab" => lab}} = envelope} =
          operation,
        result
      )
      when is_integer(chain_id) and is_map(lab) and is_map(result) do
    arguments = envelope["arguments"]

    # A verified launch is a command: the caller needs to know it landed, not the row.
    with {:ok, _auction} <-
           upsert(%{
             chain_id: chain_id,
             auction_address: result["auction"],
             creator_human_account_id: Map.get(operation, :human_account_id),
             title: arguments["name"],
             summary: arguments["description"],
             token_symbol: arguments["symbol"],
             website: arguments["website"],
             image: arguments["image"],
             quote_token_address: arguments["stock"],
             quote_token_symbol: arguments["stock_symbol"],
             quote_token_decimals: String.to_integer(arguments["stock_decimals"]),
             state: :created,
             # The auction's funds recipient: every raised STOCK goes to the launchpad,
             # which is the only custody a Stocks launch has.
             treasury_address: arguments["launchpad"]
           }),
         do: :ok
  end

  def project_launch(_operation, _result), do: :ok

  @doc "Projects one `StockLaunchCreated` observed on the chain for a creator this site knows."
  def project_observed(%{chain_id: chain_id} = attributes) when is_integer(chain_id),
    do: upsert(attributes)

  defp upsert(attributes) do
    Auction
    |> Ash.Changeset.for_create(
      :project_lab,
      attributes
      |> Map.merge(%{
        kind: :stocks,
        featured: false,
        current_clearing_price: "0"
      }),
      domain: @domain,
      actor: @actor
    )
    |> Ash.create(domain: @domain, actor: @actor)
  end
end
