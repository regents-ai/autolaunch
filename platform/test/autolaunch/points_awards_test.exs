defmodule Autolaunch.PointsAwardsTest do
  # A launch or a graduation the site saves offers Regent Points its awards in the
  # same transaction, and the site's own check (Autolaunch.Points.Launch and
  # .Graduation) answers from those saved rows. Autolaunch earns nothing (no start
  # time, no rule approved), so each test opens the three rules for itself, runs
  # the real library's queue, and reads what it wrote.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  alias Autolaunch.{Accounts, Auction, LabProjection, TestSupport}
  alias Autolaunch.Actors.System
  alias Autolaunch.Points.{Graduation, Launch}
  alias RegentPoints.Store

  @rules ["autolaunch.first_launch", "autolaunch.auction_created", "autolaunch.first_graduation"]
  @wallet "0x" <> String.duplicate("c", 40)
  @stranger "0x" <> String.duplicate("d", 40)
  @unit RegentPoints.Rules.unit()

  setup do
    # The site starts its Oban only with the database at start-up; Points queues on it.
    start_supervised!({Oban, Application.fetch_env!(:autolaunch, Oban)})

    previous =
      Map.new([:starts_at, :approved_rules], &{&1, Application.fetch_env!(:regent_points, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)

    starts_at = DateTime.add(DateTime.utc_now(), -3 * 86_400)
    Application.put_env(:regent_points, :starts_at, starts_at)
    Application.put_env(:regent_points, :approved_rules, @rules)

    account =
      Accounts.register_verified!("did:privy:points-awards", @wallet, [@wallet], actor: %System{})

    %{account: account, starts_at: starts_at}
  end

  test "a launch earns its creator the first launch once, though a second one follows",
       %{account: account} do
    first = launch(account)
    queued = length(all_enqueued(queue: :points))

    # Recording the same launch again keeps the saved row and offers nothing new.
    assert %Auction{id: id} = launch(account, address: first.auction_address)
    assert id == first.id
    assert length(all_enqueued(queue: :points)) == queued

    second = launch(account)
    drain()

    assert [%{source_event_key: key, account_id: account_id, actor_kind: "human"}] =
             events("autolaunch.first_launch")

    assert key == first.id
    assert account_id == account.id
    assert [{^key, 25}] = earned("autolaunch.first_launch")

    # The second launch still earns the day's launch award, as its own action.
    assert second.id in Enum.map(events("autolaunch.auction_created"), & &1.source_event_key)
  end

  test "the day's launch award counts once each UTC day", %{
    account: account,
    starts_at: starts_at
  } do
    # The wallet was the account's before any of the days below.
    held_since(account, @wallet, DateTime.add(starts_at, -86_400))

    two_days_ago = Date.add(Date.utc_today(), -2)
    yesterday = Date.add(Date.utc_today(), -1)

    first = account |> launch() |> saved_at(two_days_ago, ~T[10:00:00])
    same_day = account |> launch() |> saved_at(two_days_ago, ~T[11:00:00])
    next_day = account |> launch() |> saved_at(yesterday, ~T[10:00:00])
    drain()

    assert Map.new(earned("autolaunch.auction_created")) == %{
             first.id => 20,
             same_day.id => 0,
             next_day.id => 20
           }

    assert [%{reason_code: "allowance_used", cap_reduction_micro: cut}] =
             entries("autolaunch.auction_created", 0)

    assert cut == 20 * @unit
  end

  test "a graduation earns the launch's creator the first graduation once",
       %{account: account} do
    first = account |> launch(kind: :stocks, state: :graduated) |> graduate()
    queued = length(all_enqueued(queue: :points))

    # Seeing the same graduation again keeps the saved token and offers nothing new.
    {:ok, auction} = Autolaunch.get_listed_auction(first.auction_id, actor: %System{})
    assert :ok = LabProjection.project_graduated_token(auction)
    assert length(all_enqueued(queue: :points)) == queued

    account |> launch(kind: :stocks, state: :graduated) |> graduate()
    drain()

    key = first.id
    assert [{^key, 25}] = earned("autolaunch.first_graduation")
    assert [%{account_id: account_id}] = events("autolaunch.first_graduation")
    assert account_id == account.id
  end

  test "a launch from a wallet no account holds is saved and earns nothing" do
    auction =
      Autolaunch.record_launch_auction!(
        %{
          kind: :stocks,
          origin: :chain,
          contracts_version: :v2,
          featured: false,
          current_clearing_price: "0",
          chain_id: 8453,
          auction_address: "0x" <> String.duplicate("e", 40),
          token_address: "0x" <> String.duplicate("f", 40),
          creator_human_account_id: nil,
          creator_address: @stranger,
          title: "Stranger Coin",
          token_symbol: "STRG",
          quote_token_address: "0x" <> String.duplicate("a", 40),
          quote_token_symbol: "AAPLc",
          quote_token_decimals: 8,
          required_currency_raised: "1000",
          state: :created,
          treasury_address: "0x" <> String.duplicate("b", 40)
        },
        actor: %System{}
      )

    assert {:ok, %Auction{id: id}} = Autolaunch.get_listed_auction(auction.id, actor: %System{})
    drain()

    assert events() == []
    assert RegentPoints.read_entries!(actor: Store.system()) == []

    assert [
             {"autolaunch.auction_created", "creator_wallet_not_linked"},
             {"autolaunch.first_launch", "creator_wallet_not_linked"}
           ] =
             RegentPoints.read_rejections!(actor: Store.system())
             |> Enum.filter(&(&1.source["source_event_key"] == id))
             |> Enum.map(&{&1.source["rule_id"], &1.reason_code})
             |> Enum.sort()
  end

  test "while no rule is approved, launches and graduations offer nothing", %{account: account} do
    Application.put_env(:regent_points, :approved_rules, [])

    token = account |> launch(kind: :stocks, state: :graduated) |> graduate()

    assert token.graduated_at
    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
    assert RegentPoints.read_rejections!(actor: Store.system()) == []
  end

  test "the site's checks answer the same each time they are asked", %{account: account} do
    auction = launch(account, kind: :stocks, state: :graduated)
    token = graduate(auction)
    stranger = launch(account, creator_address: @stranger)
    hidden = launch(account)
    Autolaunch.hide_auction!(hidden, actor: %System{})

    for {check, record} <- [
          {Launch, auction},
          {Launch, stranger},
          {Launch, hidden},
          {Graduation, token}
        ] do
      assert check.verify(key(record)) == check.verify(key(record))
    end

    account_id = account.id
    id = auction.id
    assert {:ok, %{account_id: ^account_id, source_event_key: ^id}} = Launch.verify(key(auction))
    assert {:error, :creator_wallet_not_linked} = Launch.verify(key(stranger))
    assert {:error, :launch_not_listed} = Launch.verify(key(hidden))

    token_id = token.id

    assert {:ok, %{account_id: ^account_id, source_event_key: ^token_id}} =
             Graduation.verify(key(token))
  end

  defp launch(account, opts \\ []) do
    [creator_address: @wallet, creator_human_account_id: account.id]
    |> Keyword.merge(opts)
    |> TestSupport.project_auction()
  end

  # The token the site saves once it sees the launch's auction graduated.
  defp graduate(auction) do
    assert :ok = LabProjection.project_graduated_token(auction)
    Repo.one!(from t in Autolaunch.Token, where: t.auction_id == ^auction.id)
  end

  # The launch as though the site had saved it at that time on that day (UTC).
  defp saved_at(auction, date, time) do
    at = DateTime.new!(date, time, "Etc/UTC")

    {1, _} =
      Repo.update_all(from(a in Auction, where: a.id == ^auction.id), set: [inserted_at: at])

    auction
  end

  # A version of the account's verified wallets from an earlier time, as the
  # library's capture would have written it then.
  defp held_since(account, wallet, at) do
    Repo.query!(
      """
      INSERT INTO regent_points.wallet_snapshots(account_id, wallet_addresses, effective_at)
      VALUES ($1, $2, $3)
      """,
      [account.id, [wallet], DateTime.to_naive(at)]
    )
  end

  defp key(record), do: %{"source_event_key" => record.id}

  defp drain,
    do: assert(%{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true))

  defp events, do: RegentPoints.read_events!(actor: Store.system())
  defp events(rule), do: Enum.filter(events(), &(&1.rule_id == rule))

  defp entries(rule, points) do
    RegentPoints.read_entries!(actor: Store.system())
    |> Enum.filter(&(&1.rule_id == rule and &1.points_micro_delta == points * @unit))
  end

  # Each award a rule wrote, by the saved record it was for, in whole points.
  defp earned(rule) do
    keys = Map.new(events(rule), &{&1.id, &1.source_event_key})

    RegentPoints.read_entries!(actor: Store.system())
    |> Enum.filter(&(&1.rule_id == rule))
    |> Enum.map(&{Map.fetch!(keys, &1.event_id), div(&1.points_micro_delta, @unit)})
  end
end
