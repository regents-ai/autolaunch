defmodule AutolaunchWeb.TokenControllerTest do
  @moduledoc """
  The public token API states the same price, market cap and dollar figures
  the token lists show: its price and market cap in its currency at 18
  significant digits, and each in dollars at the currency's dollar price.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Abi
  alias Autolaunch.Stocks.MarketData
  alias Autolaunch.TestSupport

  # REGENT at fifty cents, from the pool DexScreener lists for it.
  defmodule PricedMarket do
    def get(url, _options) do
      if String.contains?(url, "/latest/dex/pairs/base/") do
        pair = %{"baseToken" => %{"address" => Abi.regent_address()}, "priceUsd" => "0.5"}
        {:ok, %{status: 200, body: %{"pairs" => [pair]}}}
      else
        {:ok, %{status: 503, body: %{}}}
      end
    end

    def post(_url, _options), do: {:ok, %{status: 503, body: %{}}}
  end

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_market_http_client)
    Application.put_env(:autolaunch, :autolaunch_market_http_client, PricedMarket)
    MarketData.reset()

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_market_http_client, previous)
      MarketData.reset()
    end)
  end

  test "a token's price and market cap read in REGENT and in dollars, list and detail alike",
       %{conn: conn} do
    auction = TestSupport.project_auction(chain_id: 8453, state: :graduated, symbol: "PRICED")

    Autolaunch.refresh_lab_market_auction!(
      auction,
      :graduated,
      "1",
      %{token_supply: Decimal.new(1_000)},
      actor: %System{}
    )

    token = TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    # A stored price runs far past what the API states.
    Autolaunch.set_subject_token_price!(
      token,
      "0.00012345678901234567890123456789",
      "pool",
      DateTime.utc_now(),
      actor: %System{}
    )

    [listed] = conn |> get("/api/v1/tokens") |> json_response(200) |> Map.fetch!("data")
    detail = conn |> get("/api/v1/tokens/#{token.id}") |> json_response(200) |> Map.fetch!("data")

    for entry <- [listed, detail] do
      assert entry["price_quote"] == "0.000123456789012345679"
      assert entry["price_usd"] == "0.0000617283945061728395"
      assert entry["market_cap"] == "0.123456789012345679"
      assert entry["market_cap_usd"] == "0.0617283945061728395"
      assert entry["quote_token"]["symbol"] == "REGENT"
    end
  end

  test "a Revstake token gives its revenue history, newest first; a Memestock token has none",
       %{conn: conn} do
    revstake = TestSupport.project_auction(chain_id: 8453, state: :graduated, symbol: "EARNS")
    token = TestSupport.project_token(auction_id: revstake.id, graduated_at: DateTime.utc_now())

    Ash.bulk_create!(
      for {block, amount, asset} <- [{110, "1.5", "USDC"}, {140, "250", "REGENT"}] do
        %{
          token_id: token.id,
          transaction_hash: "0x" <> String.duplicate(Integer.to_string(block), 21) <> "0",
          block_hash: "0x" <> String.duplicate("ab", 32),
          block_number: block,
          log_index: 0,
          occurred_at: ~U[2026-10-20 12:00:00Z],
          asset_symbol: asset,
          amount: Decimal.new(amount),
          staker_share: Decimal.new(0)
        }
      end,
      Autolaunch.TokenRevenue,
      :record,
      actor: %System{},
      return_errors?: true
    )

    memestock =
      TestSupport.project_auction(
        chain_id: 8453,
        kind: :stocks,
        state: :graduated,
        symbol: "MEME"
      )

    meme = TestSupport.project_token(auction_id: memestock.id, graduated_at: DateTime.utc_now())

    history =
      conn
      |> get("/api/v1/tokens/#{token.id}")
      |> json_response(200)
      |> get_in(["data", "revenue_history"])

    assert [%{"amount" => "250", "asset" => "REGENT"}, %{"amount" => "1.5", "asset" => "USDC"}] =
             history

    assert hd(history)["transaction_url"] =~ "https://basescan.org/tx/0x"

    assert %{"data" => %{"revenue_history" => nil}} =
             conn |> get("/api/v1/tokens/#{meme.id}") |> json_response(200)
  end
end
