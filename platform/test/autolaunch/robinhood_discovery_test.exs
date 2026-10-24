defmodule Autolaunch.Robinhood.DiscoveryTest do
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  @moduletag :capture_log

  require Ash.Query

  alias Autolaunch.Actors.System

  alias Autolaunch.{
    Auction,
    AuctionMarket,
    BaseRpcStub,
    ChainHead,
    LabAbi,
    SharedReading,
    TestSupport
  }

  alias Autolaunch.Robinhood.{Discovery, Lab}

  @chain_id 4_663
  @stock %{address: "0x2000000000000000000000000000000000000002", symbol: "TSLA", decimals: 18}
  @site_auction "0x3000000000000000000000000000000000000003"
  @outside_auction "0x4000000000000000000000000000000000000004"
  @outside_launcher "0x5000000000000000000000000000000000000005"
  @graduated_auction "0x7000000000000000000000000000000000000007"

  defmodule Chain do
    @moduledoc """
    The Robinhood chain at the JSON-RPC door, laid out by the deployment's own
    launchpad record: launches by id, each with its own token, the rollup
    clock past every end block, and one pool price for every graduated
    launch. A launch marked `unreadable_name` refuses its token's name; a
    chain marked down refuses everything. Each request for the newest block finds
    the next one.
    """
    @arb_sys "0x0000000000000000000000000000000000000064"

    def install(config, chain) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
      {:ok, contracts} = Lab.contracts(config, :v2)
      :persistent_term.put(__MODULE__, %{contracts: contracts, config: config})
      {:ok, agent} = Agent.start_link(fn -> Map.put(chain, :latest, 1_000) end)
      :persistent_term.put({__MODULE__, :agent}, agent)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def chain, do: Agent.get(agent(), & &1)
    def update(fun), do: Agent.update(agent(), fun)
    defp agent, do: :persistent_term.get({__MODULE__, :agent})

    def post(_url, options) do
      %{method: method, params: params} = options[:json]

      case answer(method, params, chain()) do
        :refused -> {:ok, %{status: 200, body: %{"error" => %{"message" => "refused"}}}}
        result -> {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer(_method, _params, %{down?: true}), do: :refused
    defp answer("eth_chainId", _params, _chain), do: "0x1237"

    defp answer("eth_getBlockByNumber", ["latest", _full?], _chain) do
      Agent.get_and_update(:persistent_term.get({__MODULE__, :agent}), fn chain ->
        {chain.latest + 1, %{chain | latest: chain.latest + 1}}
      end)
      |> block()
    end

    defp answer("eth_getBlockByNumber", ["0x" <> number, _full?], _chain),
      do: number |> String.to_integer(16) |> block()

    defp answer("eth_call", [%{to: to, data: data}, _block], chain) do
      %{contracts: contracts, config: config} = :persistent_term.get(__MODULE__)
      selector = String.slice(data, 0, 10)
      argument = String.slice(data, 10, 64)

      cond do
        to == @arb_sys -> word(chain.clock)
        to == contracts.launchpad -> launchpad(selector, argument, chain, contracts)
        to == Lab.address!(config, :pool_manager) -> word(chain.sqrt_price)
        launch = Enum.find(chain.launches, &(&1.auction == to)) -> auction(selector, launch)
        launch = Enum.find(chain.launches, &(&1.token == to)) -> token(selector, launch)
        true -> :refused
      end
    end

    defp launchpad(selector, argument, chain, contracts) do
      cond do
        selector == LabAbi.selector("nextLaunchId()") ->
          word(length(chain.launches) + 1)

        selector == LabAbi.selector("launches(uint256)") ->
          launch = Enum.at(chain.launches, String.to_integer(argument, 16) - 1)
          words(Enum.map(contracts.record_fields, &field(launch, &1)))

        selector == LabAbi.selector("launchIdOfAuction(address)") ->
          word(
            Enum.find(chain.launches, &(number(&1.auction) == String.to_integer(argument, 16))).id
          )
      end
    end

    defp field(launch, :launcher), do: number(launch.launcher)
    defp field(launch, :new_token), do: number(launch.token)
    defp field(_launch, :currency), do: number("0x2000000000000000000000000000000000000002")
    defp field(launch, :auction), do: number(launch.auction)
    defp field(_launch, :start_block), do: 100
    defp field(_launch, :end_block), do: 200
    defp field(launch, :lifecycle), do: launch.lifecycle
    defp field(%{lifecycle: 2} = launch, :pool_id), do: launch.id

    defp field(%{lifecycle: 2}, :splitter),
      do: number("0x8000000000000000000000000000000000000008")

    defp field(%{lifecycle: 2}, :lp_token_id), do: 7
    defp field(_launch, _field), do: 0

    defp auction(selector, launch) do
      %{
        LabAbi.selector("isGraduated()") => word(if(launch.minimum_reached, do: 1, else: 0)),
        LabAbi.selector("clearingPrice()") => word(0),
        LabAbi.selector("currencyRaised()") => word(2 * 10 ** 18),
        LabAbi.selector("floorPrice()") => word(7 * 2 ** 96),
        LabAbi.selector("token()") => word(number(launch.token))
      }
      |> Map.get(selector, :refused)
    end

    defp token(selector, launch) do
      cond do
        selector == LabAbi.selector("totalSupply()") ->
          word(1_000_000 * 10 ** 18)

        launch[:unreadable_name] ->
          :refused

        selector == LabAbi.selector("name()") ->
          string(launch.name)

        selector == LabAbi.selector("symbol()") ->
          string(launch.symbol)

        selector == LabAbi.selector("tokenURI()") ->
          string("data:application/json;base64," <> Base.encode64("{}"))

        true ->
          :refused
      end
    end

    defp block(number),
      do: %{
        "number" => "0x" <> Integer.to_string(number, 16),
        "hash" => "0x" <> BaseRpcStub.hex_word(number),
        "timestamp" => "0x" <> Integer.to_string(0x6700 + number, 16)
      }

    defp number("0x" <> hex), do: String.to_integer(hex, 16)
    defp word(value), do: "0x" <> BaseRpcStub.hex_word(value)
    defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)

    defp string(value) do
      hex = Base.encode16(value, case: :lower)
      padded = String.pad_trailing(hex, div(byte_size(hex) + 63, 64) * 64, "0")
      "0x" <> BaseRpcStub.hex_word(32) <> BaseRpcStub.hex_word(byte_size(value)) <> padded
    end
  end

  setup do
    config = deployment()
    creator = TestSupport.register_creator!()

    Autolaunch.record_stock_admission!(
      %{
        chain_id: @chain_id,
        address: @stock.address,
        symbol: @stock.symbol,
        name: "Tesla",
        decimals: @stock.decimals,
        route: "0x547f3b931eaf75bab98364ab396058ddc2e68e4a",
        admitted: true
      },
      actor: %System{}
    )

    # The site prepared launch 1 for this creator; nothing else was prepared
    # here, and no browser ever reports a launch in these tests.
    review(creator, "Launch 1", "L1")

    Chain.install(config, %{
      down?: false,
      clock: 250,
      sqrt_price: 0,
      launches: [
        # Minimum reached and past the end block, not yet migrated.
        launch(1, @site_auction, creator.wallet_address, 1, true),
        # Migrated as failed.
        launch(2, @outside_auction, @outside_launcher, 3, false)
      ]
    })

    %{creator: creator}
  end

  test "every launchpad record becomes one row, the site's own marked apart, and a second pass changes nothing",
       %{creator: creator} do
    assert {:snooze, 300} = discover()

    rows = robinhood_rows()
    assert length(rows) == 2

    site = row(@site_auction)
    outside = row(@outside_auction)

    assert %{kind: :stocks, origin: :site, state: :ended} = site
    assert site.creator_human_account_id == creator.id
    assert site.quote_token_symbol == "TSLA"
    assert site.required_currency_raised == "26969530"
    assert site.treasury_address == launchpad()

    # The launch's facts from its launchpad record, the schedule in the rollup
    # clock.
    assert %{launch_id: 1, start_block: 100, end_block: 200} = site
    assert %{launch_id: 2, start_block: 100, end_block: 200} = outside
    assert %{origin: :chain, state: :failed} = outside
    assert outside.creator_human_account_id == nil

    # Its reading job then reads the auction's figures.
    read_all()
    assert %{state: :ended, minimum_reached: true, currency_raised: raised} = row(@site_auction)
    assert Decimal.eq?(raised, 2)

    facts = &Map.take(&1, [:id, :state, :token_address, :launch_id, :start_block, :end_block])
    before = Enum.map(robinhood_rows(), facts)

    assert {:snooze, 300} = discover()
    read_all()
    assert Enum.map(robinhood_rows(), facts) == before
  end

  test "an unreadable record is read again later without holding back the launches after it" do
    Chain.update(fn chain ->
      %{chain | launches: List.update_at(chain.launches, 0, &Map.put(&1, :unreadable_name, true))}
    end)

    assert {:snooze, 300} = discover()
    assert Enum.map(robinhood_rows(), & &1.auction_address) == [@outside_auction]

    # A third launch arrives while the first still cannot be read.
    Chain.update(fn chain ->
      %{
        chain
        | launches: chain.launches ++ [launch(3, @graduated_auction, @outside_launcher, 2, true)]
      }
    end)

    assert {:snooze, 300} = discover()
    assert length(robinhood_rows()) == 2

    # Once the first record reads, it is listed.
    Chain.update(fn chain ->
      %{chain | launches: List.update_at(chain.launches, 0, &Map.delete(&1, :unreadable_name))}
    end)

    assert {:snooze, 300} = discover()
    assert length(robinhood_rows()) == 3
  end

  test "a launch whose name and symbol are the chain's own graduates with its token" do
    name = "A launch named " <> String.duplicate("at length ", 12) <> "on chain, long!"

    graduated = %{
      launch(3, @graduated_auction, @outside_launcher, 2, true)
      | name: name,
        symbol: "meme"
    }

    Chain.update(&%{&1 | launches: &1.launches ++ [graduated]})

    assert {:snooze, 300} = discover()
    assert %{state: :graduated, token_symbol: "meme"} = row(@graduated_auction)

    assert {:ok, token} =
             Autolaunch.get_token_for_projection(row(@graduated_auction).id, actor: %System{})

    assert %{symbol: "meme"} = token
    assert token.name == name
    assert String.length(name) == 150
  end

  test "a row another writer wrote first keeps its details and state" do
    first = %{
      kind: :stocks,
      origin: :site,
      chain_id: @chain_id,
      auction_address: @site_auction,
      creator_address: "0x1414141414141414141414141414141414141414",
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
      treasury_address: launchpad()
    }

    {:ok, written} = Autolaunch.record_launch_auction(first, actor: %System{})

    # Discovery's own insert, landing after the other writer's: it is handed
    # the stored row and changes nothing.
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

    # Its reading job moves only its market fields.
    assert {:snooze, 300} = pass(written)
    assert %{title: "Written first", summary: "Its own words", state: :ended} = row(@site_auction)
  end

  test "a Robinhood outage marks the chain stale and the readings degraded, and leaves every row as it was" do
    assert {:snooze, 300} = discover()
    read_all()
    rows = robinhood_rows()

    # Whatever an earlier case left, so each change below is one this case made.
    key = ChainHead.key("robinhood")
    SharedReading.delete(key)
    SharedReading.subscribe(key)
    head = start_supervised!({ChainHead, {"robinhood", 60_000}})
    assert_receive {:shared_reading, ^key}, 2_000
    refute ChainHead.stale?("robinhood")

    Chain.update(&%{&1 | down?: true})
    send(head, :read)
    assert_receive {:shared_reading, ^key}, 2_000
    assert ChainHead.stale?("robinhood")

    assert {:snooze, 60} = pass(row(@site_auction))

    assert {:ok, %{degraded: true}} =
             Autolaunch.get_auction_reading(row(@site_auction).id, actor: nil)

    assert robinhood_rows() == rows
    assert {:snooze, 60} = discover()

    # The public list carries the site's Robinhood launch as last stored; the
    # launch seen only on chain is stored but not listed.
    {:ok, listed} = Autolaunch.HomeMarket.read(Autolaunch.HomeMarket.options(%{"state" => "all"}))
    assert Enum.map(listed.records, & &1.auction_address) == [@site_auction]
  end

  test "a launch that graduates gets exactly one token, and a failed one gets none" do
    assert {:snooze, 300} = discover()
    read_all()
    assert Enum.map([@site_auction, @outside_auction], &tokens/1) == [0, 0]

    # `migrate` graduates the site launch, and a third launch appears already
    # graduated.
    Chain.update(fn chain ->
      %{
        chain
        | launches:
            List.update_at(chain.launches, 0, &%{&1 | lifecycle: 2}) ++
              [launch(3, @graduated_auction, @outside_launcher, 2, true)]
      }
    end)

    assert {:snooze, 300} = discover()
    read_all()
    assert Enum.map([@site_auction, @graduated_auction, @outside_auction], &tokens/1) == [1, 1, 0]

    # Reading every auction again leaves one token each.
    read_all()
    assert Enum.map([@site_auction, @graduated_auction, @outside_auction], &tokens/1) == [1, 1, 0]

    assert {:ok, %{name: "Launch 1", symbol: "L1", subject_id: nil} = token} =
             Autolaunch.get_token_for_projection(row(@site_auction).id, actor: %System{})

    assert token.treasury_address == launchpad()
  end

  test "a graduated token takes its pool's price, and follows it" do
    Chain.update(fn chain ->
      %{
        chain
        | sqrt_price: 2 ** 96,
          launches: List.update_at(chain.launches, 0, &%{&1 | lifecycle: 2})
      }
    end)

    assert {:snooze, 300} = discover()
    read_all()
    first = price(@site_auction)
    assert first

    Chain.update(&%{&1 | sqrt_price: 2 * 2 ** 96})
    read_all()
    refute price(@site_auction) == first
  end

  test "a launch from a creator's wallet that no review of this site prepared is seen on chain only",
       %{creator: creator} do
    # The same wallet launches again, directly, under a name it never
    # reviewed here.
    direct = launch(3, @graduated_auction, creator.wallet_address, 1, false)
    Chain.update(&%{&1 | launches: &1.launches ++ [direct]})

    assert {:snooze, 300} = discover()

    assert %{origin: :chain, creator_human_account_id: nil} = row(@graduated_auction)
    assert %{origin: :site} = row(@site_auction)

    {:ok, listed} = Autolaunch.HomeMarket.read(Autolaunch.HomeMarket.options(%{"state" => "all"}))
    assert Enum.map(listed.records, & &1.auction_address) == [@site_auction]
  end

  # The shipped Robinhood deployment, answering at a loopback door this test
  # stands in for.
  defp deployment do
    path =
      Path.join(
        Elixir.System.tmp_dir!(),
        "robinhood-#{Elixir.System.unique_integer([:positive])}.json"
      )

    "deployment/robinhood.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(%{"rpc_url" => "http://127.0.0.1:18545", "public_rpc_url" => nil})
    |> Jason.encode!()
    |> then(&File.write!(path, &1))

    put_env(:autolaunch_robinhood_deployment, path)
    put_env(:autolaunch_robinhood_chain_id, @chain_id)
    on_exit(fn -> File.rm(path) end)
    {:ok, config} = Lab.current()
    config
  end

  defp put_env(key, value) do
    previous = Application.get_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)
    on_exit(fn -> restore_env(key, previous) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore_env(key, previous), do: Application.put_env(:autolaunch, key, previous)

  defp launchpad, do: Lab.address!(elem(Lab.current(), 1), :stocks_launchpad)

  defp discover, do: perform_job(Discovery, %{})
  defp pass(auction), do: perform_job(AuctionMarket, %{auction_id: auction.id})
  defp read_all, do: Enum.each(robinhood_rows(), &({:snooze, _wait} = pass(&1)))

  defp price(auction_address) do
    {:ok, token} = Autolaunch.get_token_for_projection(row(auction_address).id, actor: %System{})
    assert token.price_source == "pool"
    token.price_quote
  end

  defp row(auction_address),
    do: Enum.find(robinhood_rows(), &(&1.auction_address == auction_address))

  defp tokens(auction_address) do
    # Counts the rows written, whatever policies would show a reader.
    Repo.one(
      from token in "tokens",
        join: auction in "auctions",
        on: auction.id == token.auction_id,
        where: auction.chain_id == @chain_id and auction.auction_address == ^auction_address,
        select: count(token.id)
    )
  end

  defp launch(id, auction, launcher, lifecycle, minimum_reached) do
    %{
      id: id,
      launcher: String.downcase(launcher),
      token:
        "0x60000000000000000000000000000000000000" <>
          String.pad_leading(Integer.to_string(id), 2, "0"),
      auction: auction,
      name: "Launch #{id}",
      symbol: "L#{id}",
      lifecycle: lifecycle,
      minimum_reached: minimum_reached
    }
  end

  defp review(creator, name, symbol) do
    Autolaunch.record_robinhood_launch_review!(
      %{
        chain_id: @chain_id,
        signer: String.downcase(creator.wallet_address),
        human_account_id: creator.id,
        name: name,
        symbol: symbol,
        stock: @stock.address
      },
      actor: %System{}
    )
  end

  defp robinhood_rows do
    # Every stored row on the chain, open and finished, beneath every listing
    # policy.
    Auction
    |> Ash.Query.for_read(:market, %{}, actor: %System{})
    |> Ash.Query.filter(chain_id == ^@chain_id)
    |> Ash.Query.sort(:auction_address)
    |> Ash.read!()
  end
end
