defmodule AutolaunchWeb.TokensLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Repo
  alias Autolaunch.Tokens

  test "/tokens shows the empty graduated-token state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tokens")

    assert html =~ "Revsplit Tokens"
    assert html =~ "No graduated tokens yet."
    assert html =~ "Graduated auction tokens will appear here after the market clears."
    assert html =~ ~s(data-nav-section="tokens")
  end

  test "/tokens lists graduated tokens and omits failed auctions", %{conn: conn} do
    insert_revsplit_token(%{
      token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      source_auction_id: "auc_atlas",
      agent_id: "8453:101",
      agent_name: "Atlas Agent",
      token_symbol: "ATLAS",
      auction_raise_quote: "2.5",
      required_raise_quote: "2",
      price_quote: "0.0123",
      fdv_quote: "1230000000"
    })

    insert_failed_auction("Failed Agent")

    {:ok, view, html} = live(conn, "/tokens")

    assert html =~ "Trending"
    assert html =~ "New"
    assert html =~ "Top raise"
    assert html =~ "Atlas Agent"
    assert html =~ "ATLAS"
    assert html =~ "0.012300 $REGENT"
    assert html =~ "2.5 $REGENT"
    assert html =~ "2.0 $REGENT"
    assert html =~ "1,230,000,000.0 $REGENT"
    assert html =~ "Active"
    refute html =~ "Failed Agent"
    refute has_element?(view, "[data-swap-open]")
    assert has_element?(view, "#token-8453-0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  end

  test "/tokens shows swap controls only when swaps are available", %{conn: conn} do
    previous_swaps = Application.get_env(:autolaunch, :swaps, [])

    Application.put_env(
      :autolaunch,
      :swaps,
      Keyword.merge(previous_swaps,
        enabled: true,
        uniswap_api_key: "test-key",
        allowed_transaction_targets: %{8_453 => ["0x3333333333333333333333333333333333333333"]},
        allowed_approval_spenders: %{8_453 => ["0x2222222222222222222222222222222222222222"]}
      )
    )

    on_exit(fn -> Application.put_env(:autolaunch, :swaps, previous_swaps) end)

    insert_revsplit_token(%{
      token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      source_auction_id: "auc_atlas",
      agent_name: "Atlas Agent",
      token_symbol: "ATLAS"
    })

    insert_revsplit_token(%{
      token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      source_auction_id: "auc_paused",
      agent_name: "Paused Agent",
      token_symbol: "PAUS",
      revsplit_status: "paused"
    })

    {:ok, view, _html} = live(conn, "/tokens")

    assert has_element?(
             view,
             "#token-8453-0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb [data-swap-open][data-swap-side='buy']"
           )

    refute has_element?(
             view,
             "#token-8453-0xdddddddddddddddddddddddddddddddddddddddd [data-swap-open]"
           )
  end

  test "/tokens search narrows the table", %{conn: conn} do
    insert_revsplit_token(%{
      token_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      source_auction_id: "auc_atlas",
      agent_id: "8453:201",
      agent_name: "Atlas Agent",
      token_symbol: "ATLAS"
    })

    insert_revsplit_token(%{
      token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      source_auction_id: "auc_cinder",
      agent_id: "8453:202",
      agent_name: "Cinder Agent",
      token_symbol: "CNDR"
    })

    {:ok, view, _html} = live(conn, "/tokens")

    _html =
      view
      |> form("form[phx-change='filters_changed']", %{
        "filters" => %{"sort" => "trending", "search" => "cndr"}
      })
      |> render_change()

    html = render(view)
    assert html =~ "Cinder Agent"
    refute html =~ "Atlas Agent"
  end

  defp insert_revsplit_token(attrs) do
    now = DateTime.utc_now()

    {:ok, token} =
      Tokens.upsert_revsplit_token(
        Map.merge(
          %{
            chain_id: 8_453,
            token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            source_auction_id: "auc_default",
            source_job_id: "job_default",
            auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            agent_id: "8453:1",
            agent_name: "Default Agent",
            token_symbol: "DFLT",
            subject_id: "0x" <> String.duplicate("1", 64),
            splitter_address: "0xcccccccccccccccccccccccccccccccccccccccc",
            pool_id: "0x" <> String.duplicate("2", 64),
            graduated_at: DateTime.add(now, -3_600, :second),
            graduation_block: 200,
            auction_raise_raw: "2500000",
            auction_raise_quote: "2.5",
            required_raise_raw: "2000000",
            required_raise_quote: "2",
            clearing_price_quote: "0.01",
            price_quote: nil,
            price_source: "uniswap_spot_unavailable",
            price_updated_at: nil,
            fdv_quote: nil,
            revsplit_status: "active",
            last_synced_at: now
          },
          attrs
        )
      )

    token
  end

  defp insert_failed_auction(agent_name) do
    now = DateTime.utc_now()

    %Auction{}
    |> Auction.changeset(%{
      source_job_id: "auc_failed_live_test",
      agent_id: "8453:303",
      agent_name: agent_name,
      owner_address: "0x1111111111111111111111111111111111111111",
      auction_address: "0xffffffffffffffffffffffffffffffffffffffff",
      token_address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      network: "base-mainnet",
      chain_id: 8_453,
      status: "active",
      started_at: DateTime.add(now, -7_200, :second),
      ends_at: DateTime.add(now, -3_600, :second),
      minimum_raise_quote: "2",
      minimum_raise_quote_raw: "2000000000000000000",
      chain_state: "failed_minimum",
      onchain_graduated: false
    })
    |> Repo.insert!()
  end
end
