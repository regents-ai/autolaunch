defmodule Autolaunch.Robinhood.MarketFeedTest do
  use Autolaunch.DataCase, async: false

  @moduletag :capture_log

  alias Autolaunch.Actors.System
  alias Autolaunch.{MarketWatch, TestSupport}
  alias Autolaunch.Robinhood.MarketFeed

  @chain_id 4_663
  @launchpad "0x1000000000000000000000000000000000000001"
  @stock %{address: "0x2000000000000000000000000000000000000002", symbol: "TSLA", decimals: 18}
  @site_auction "0x3000000000000000000000000000000000000003"
  @outside_auction "0x4000000000000000000000000000000000000004"
  @outside_launcher "0x5000000000000000000000000000000000000005"
  @graduated_auction "0x7000000000000000000000000000000000000007"
  @splitter "0x8000000000000000000000000000000000000008"

  defmodule Chain do
    @moduledoc """
    The Robinhood chain as the feed's reader: two launches, the rollup clock
    past both end blocks, and every market's answer settable per auction. A
    chain marked down refuses the head.
    """
    def put(chain), do: :persistent_term.put(__MODULE__, chain)
    def chain, do: :persistent_term.get(__MODULE__)

    def head do
      case chain() do
        %{down?: true} ->
          {:error, :chain_unavailable}

        chain ->
          {:ok,
           %{
             chain_id: 4_663,
             clock: chain.clock,
             block: %{number: chain.clock, hash: "0x" <> String.duplicate("ef", 32)}
           }}
      end
    end

    def next_launch_id(_head), do: {:ok, length(chain().launches) + 1}
    def launch(_head, id), do: {:ok, Enum.at(chain().launches, id - 1)}
    def market(_head, auction), do: Map.fetch(chain().markets, auction)

    def price_quote(_head, %{pool_id: pool_id}, 18) do
      case Map.fetch(chain().prices, pool_id) do
        {:ok, :unreadable} -> {:error, :chain_unavailable}
        {:ok, price} -> {:ok, price}
        :error -> {:ok, nil}
      end
    end
  end

  setup do
    creator = TestSupport.register_creator!()

    Chain.put(%{
      down?: false,
      clock: 250,
      prices: %{},
      launches: [
        # A checksummed launcher still names its creator.
        launch(
          1,
          @site_auction,
          "0x" <> String.upcase(String.slice(creator.wallet_address, 2..-1//1))
        ),
        launch(2, @outside_auction, @outside_launcher)
      ],
      markets: %{
        # Minimum reached and past the end block, not yet migrated.
        @site_auction => market(1, 1, true),
        # Migrated as failed.
        @outside_auction => market(2, 3, false)
      }
    })

    %{creator: creator}
  end

  test "every launchpad record becomes one row, and replaying it changes nothing", %{
    creator: creator
  } do
    assert {:ok, first} = MarketFeed.poll(Chain, %{watch: MarketWatch.new(), next_launch_id: 1})
    assert first.cursors.next_launch_id == 3

    rows = robinhood_rows()
    assert length(rows) == 2

    site = Enum.find(rows, &(&1.auction_address == @site_auction))
    outside = Enum.find(rows, &(&1.auction_address == @outside_auction))

    assert %{kind: :stocks, state: :ended, minimum_reached: true} = site
    assert site.creator_human_account_id == creator.id
    assert site.quote_token_symbol == "TSLA"
    assert site.required_currency_raised == "1000"
    assert site.treasury_address == @launchpad

    assert %{state: :failed, minimum_reached: false, creator_human_account_id: nil} = outside

    # The next poll reads no record twice; a restarted feed reads them all
    # again, and neither duplicates a row nor moves a state back.
    assert {:ok, %{changed: []}} = MarketFeed.poll(Chain, first.cursors)

    assert {:ok, _replayed} =
             MarketFeed.poll(Chain, %{watch: MarketWatch.new(), next_launch_id: 1})

    assert robinhood_rows() |> Enum.map(&{&1.id, &1.state}) |> Enum.sort() ==
             rows |> Enum.map(&{&1.id, &1.state}) |> Enum.sort()

    assert first.snapshots[@site_auction].currency_raised == "2"
  end

  test "a row another writer wrote first keeps its details and state" do
    first = %{
      kind: :stocks,
      chain_id: @chain_id,
      auction_address: @site_auction,
      title: "Written first",
      summary: "Its own words",
      token_symbol: "FIRST",
      website: "https://example.com",
      image: "https://example.com/first.png",
      featured: false,
      state: :active,
      quote_token_address: @stock.address,
      quote_token_symbol: "TSLA",
      quote_token_decimals: 18,
      current_clearing_price: "0",
      required_currency_raised: "1000",
      treasury_address: @launchpad
    }

    {:ok, written} = Autolaunch.record_launch_auction(first, actor: %System{})

    # The feed's own insert, landing after the other writer's: it is handed the
    # stored row and changes nothing.
    assert {:ok, kept} =
             Autolaunch.record_launch_auction(
               %{
                 first
                 | title: "Launch 1",
                   summary: nil,
                   website: nil,
                   image: nil,
                   state: :created
               },
               actor: %System{}
             )

    assert kept.id == written.id
    stored = row(@site_auction)
    assert %{title: "Written first", summary: "Its own words", state: :active} = stored
    assert stored.website == "https://example.com"

    # A poll reads it as an existing row: only its market fields move.
    assert {:ok, _poll} = MarketFeed.poll(Chain, %{watch: MarketWatch.new(), next_launch_id: 1})

    assert %{title: "Written first", summary: "Its own words", state: :ended} =
             row(@site_auction)

    assert length(robinhood_rows()) == 2
  end

  test "a Robinhood outage marks its readings stale and leaves every row, Base included, as it was" do
    base = TestSupport.project_auction(chain_id: 8453, state: :active)
    previous = Application.get_env(:autolaunch, :autolaunch_robinhood_chain_id)
    Application.put_env(:autolaunch, :autolaunch_robinhood_chain_id, @chain_id)
    on_exit(fn -> Application.put_env(:autolaunch, :autolaunch_robinhood_chain_id, previous) end)

    Phoenix.PubSub.subscribe(Autolaunch.PubSub, MarketFeed.topic())
    {:ok, feed} = MarketFeed.start_link(name: nil, poll?: false, reader: Chain)

    MarketFeed.refresh(feed)
    assert_receive {:robinhood_market_updated, %{stale?: false}}, 2_000
    rows = robinhood_rows()

    Chain.put(%{Chain.chain() | down?: true})
    MarketFeed.refresh(feed)
    assert_receive {:robinhood_market_updated, %{stale?: true, auction_ids: []}}, 2_000

    assert %{stale?: true, auctions: %{@site_auction => %{state: :ended}}} =
             MarketFeed.snapshot(feed)

    assert robinhood_rows() == rows
    assert [%{id: base_id, state: :active}] = base_rows()
    assert base_id == base.id

    # The public list carries the Robinhood rows as last stored, beside Base.
    listed = Autolaunch.page_public_auctions!("all", "newest", actor: nil)

    assert Enum.sort(Enum.map(listed.results, & &1.id)) ==
             Enum.sort([base.id | Enum.map(rows, & &1.id)])
  end

  test "a launch that graduates gets exactly one token, and a failed one gets none" do
    assert {:ok, first} = MarketFeed.poll(Chain, %{watch: MarketWatch.new(), next_launch_id: 1})
    assert tokens(@site_auction) == 0
    assert tokens(@outside_auction) == 0

    # `migrate` graduates the site launch, and a third launch appears already
    # graduated.
    Chain.put(%{
      Chain.chain()
      | launches: Chain.chain().launches ++ [launch(3, @graduated_auction, @outside_launcher, 2)],
        markets:
          Chain.chain().markets
          |> Map.put(@site_auction, market(1, 2, true))
          |> Map.put(@graduated_auction, market(3, 2, true))
    })

    assert {:ok, second} = MarketFeed.poll(Chain, first.cursors)
    assert tokens(@site_auction) == 1
    assert tokens(@graduated_auction) == 1
    assert tokens(@outside_auction) == 0

    site_pool = pool_id(1)

    assert %{state: :graduated, pool: %{pool_id: ^site_pool, splitter: @splitter}} =
             second.snapshots[@site_auction]

    # Replaying every record and every market leaves one token each.
    assert {:ok, _replayed} =
             MarketFeed.poll(Chain, %{watch: MarketWatch.new(), next_launch_id: 1})

    assert {:ok, _again} = MarketFeed.poll(Chain, second.cursors)
    assert Enum.map([@site_auction, @graduated_auction, @outside_auction], &tokens/1) == [1, 1, 0]

    site = Enum.find(robinhood_rows(), &(&1.auction_address == @site_auction))

    assert {:ok, %{name: "Launch 1", symbol: "L1", subject_id: nil} = token} =
             Autolaunch.get_public_token_by_auction(site.id, actor: nil)

    assert token.treasury_address == @launchpad
  end

  test "a graduated token takes its pool's price on each finished pass, and one unreadable price leaves the others" do
    Chain.put(%{
      Chain.chain()
      | launches: Chain.chain().launches ++ [launch(3, @graduated_auction, @outside_launcher, 2)],
        markets:
          Chain.chain().markets
          |> Map.put(@site_auction, market(1, 2, true))
          |> Map.put(@graduated_auction, market(3, 2, true)),
        prices: %{pool_id(1) => "1.5", pool_id(3) => "0.25"}
    })

    assert {:ok, first} = MarketFeed.poll(Chain, %{watch: MarketWatch.new(), next_launch_id: 1})
    assert price(@site_auction) == "1.5"
    assert price(@graduated_auction) == "0.25"

    # The site pool moves; the other pool cannot be read on the next pass that
    # reads finished auctions.
    Chain.put(%{Chain.chain() | prices: %{pool_id(1) => "2", pool_id(3) => :unreadable}})
    site = row(@site_auction)

    assert {:ok, second} = finished_pass(first.cursors)
    assert second.changed == [site.id]
    assert price(@site_auction) == "2"
    assert price(@graduated_auction) == "0.25"
    assert %{state: :graduated} = second.snapshots[@graduated_auction]

    # An unchanged price changes nothing.
    Chain.put(%{Chain.chain() | prices: %{pool_id(1) => "2", pool_id(3) => "0.25"}})
    assert {:ok, %{changed: []}} = finished_pass(second.cursors)
  end

  # Finished auctions are read on every fourth pass; the passes between read
  # only the open ones, so they leave these prices alone.
  defp finished_pass(cursors) do
    Enum.reduce(1..3, cursors, fn _pass, cursors ->
      assert {:ok, %{changed: [], cursors: next}} = MarketFeed.poll(Chain, cursors)
      next
    end)
    |> then(&MarketFeed.poll(Chain, &1))
  end

  defp price(auction_address) do
    {:ok, token} =
      Autolaunch.get_token_for_projection(row(auction_address).id, actor: %System{})

    assert token.price_source == "pool"
    token.price_quote
  end

  defp row(auction_address),
    do: Enum.find(robinhood_rows(), &(&1.auction_address == auction_address))

  defp pool_id(launch_id),
    do: "0x" <> String.pad_leading(Integer.to_string(launch_id, 16), 64, "0")

  defp tokens(auction_address) do
    Repo.one(
      from token in "tokens",
        join: auction in "auctions",
        on: auction.id == token.auction_id,
        where: auction.chain_id == @chain_id and auction.auction_address == ^auction_address,
        select: count(token.id)
    )
  end

  defp launch(id, auction, launcher, lifecycle \\ 1) do
    %{
      launch_id: id,
      launcher: launcher,
      token: "0x6000000000000000000000000000000000000006",
      auction: auction,
      launchpad: @launchpad,
      stock: @stock,
      name: "Launch #{id}",
      symbol: "L#{id}",
      description: nil,
      website: nil,
      image: nil,
      start_block: 100,
      end_block: 200,
      required: 1_000,
      lifecycle: lifecycle
    }
  end

  defp market(launch_id, lifecycle, minimum_reached) do
    %{
      launch_id: launch_id,
      lifecycle: lifecycle,
      start_block: 100,
      end_block: 200,
      minimum_reached: minimum_reached,
      clearing_price_q96: 0,
      currency_raised: 2 * 10 ** 18,
      pool:
        if(lifecycle == 2,
          do: %{
            pool_id: pool_id(launch_id),
            token: "0x6000000000000000000000000000000000000006",
            stock: @stock.address,
            splitter: @splitter,
            lp_token_id: 7,
            locker: @launchpad
          }
        )
    }
  end

  defp robinhood_rows, do: rows(@chain_id, :stocks)
  defp base_rows, do: rows(8453, :agent)

  # Every stored row of one kind on one chain, open and finished, beneath
  # every listing policy.
  defp rows(chain_id, kind) do
    [false, true]
    |> Enum.flat_map(
      &Autolaunch.list_market_watch_auctions!(chain_id, kind, &1, nil, 500, actor: %System{})
    )
    |> Enum.sort_by(& &1.auction_address)
  end
end
