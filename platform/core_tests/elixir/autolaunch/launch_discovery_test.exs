defmodule Autolaunch.LaunchDiscoveryTest do
  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch.{Accounts, Auction, Lab, LaunchDiscovery, LaunchFixture, LaunchProjection}
  alias Autolaunch.{LaunchOperation, WalletAttempt}
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Abi, LaunchAbi}

  @actor %System{}
  @hash "0x" <> String.duplicate("4c", 32)
  @auction "0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  @subject "0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  @escrow "0xc3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
  @stranger "0x9999999999999999999999999999999999999999"
  @other_wallet "0x2222222222222222222222222222222222222222"

  setup do
    LaunchFixture.install(
      outcomes: %{
        launch: %{
          outcome: :confirmed,
          result: %{
            "launch_id" => "7",
            "subject" => @subject,
            "auction" => @auction,
            "escrow" => @escrow,
            "treasury" => LaunchFixture.treasury(),
            "start_block" => "30001800",
            "end_block" => "30088201"
          }
        }
      }
    )

    # The site starts its jobs only once launches open; the test runs them by hand.
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    context = LaunchFixture.actor()
    operation = review!(context[:account], context[:draft], LaunchFixture.wallet())
    context |> Map.new() |> Map.put(:operation, operation)
  end

  test "a launch whose browser never reported its hash is listed once, for its creator",
       %{account: account, operation: operation} do
    # The wallet opened, the transaction went out, and the page was closed.
    {:ok, _} = press(operation)

    record_launch(LaunchFixture.wallet())
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [auction] = auctions()
    assert auction.creator_human_account_id == account.id
    assert auction.state == :created

    assert %{state: :chain_verified, terminal_at: %DateTime{}} = reload(operation)
    assert [%{state: :confirmed, transaction_hash: @hash}] = attempts(operation)
  end

  test "a replayed launch lists nothing twice and takes no auction back to its start",
       %{account: account, operation: operation, opts: opts} do
    {:ok, first} = press(operation)
    {:ok, second} = press(operation)

    record_launch(LaunchFixture.wallet())
    run_triggers()

    [auction] = auctions()

    {:ok, _} =
      auction
      |> Ash.Changeset.for_update(:refresh_lab_market, %{state: :graduated}, actor: @actor)
      |> Ash.update(actor: @actor)

    # The ledger replays the same log, and the other press's page reports the
    # same hash and checks it after all.
    record_launch(LaunchFixture.wallet())
    run_triggers()

    unfilled =
      Enum.find([first, second], fn %{id: id} ->
        Enum.any?(attempts(operation), &(&1.id == id and is_nil(&1.transaction_hash)))
      end)

    {:ok, _} =
      Autolaunch.report_wallet_press(
        :launch,
        operation.action_id,
        unfilled.id,
        %{"transaction_hash" => @hash},
        opts
      )

    {:ok, _} =
      Autolaunch.verify_wallet_press(:launch, operation.action_id, unfilled.id, opts)

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [%{state: :graduated, creator_human_account_id: ^creator}] = auctions()
  end

  test "a launch no review of this site carried out stays unlisted" do
    record_launch(@stranger)
    run_triggers()

    assert [%{state: :unlisted, reason: "no_matching_review"}] = discoveries()
    assert auctions() == []
  end

  test "a hash another account reported is listed for the account whose review sent it",
       %{account: account, operation: operation} do
    other =
      Accounts.register_verified!(
        "did:privy:other-#{Elixir.System.unique_integer([:positive])}",
        @other_wallet,
        [@other_wallet],
        actor: @actor
      )

    # The other account's own review, onto which it reports this launch's hash.
    other_draft = LaunchFixture.draft!(%Autolaunch.Actors.Human{human_account_id: other.id})

    other_operation = review!(other, other_draft, @other_wallet)

    {:ok, _} =
      WalletAttempt
      |> Ash.Changeset.for_create(
        :dispatch,
        %{
          launch_operation_id: other_operation.id,
          step: :launch,
          envelope: other_operation.envelope,
          state: :submitted,
          transaction_hash: @hash
        },
        actor: @actor
      )
      |> Ash.create(actor: @actor)

    record_launch(LaunchFixture.wallet())
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [%{creator_human_account_id: ^creator}] = auctions()
    assert %{state: :chain_verified} = reload(operation)
    assert %{state: :prepared, terminal_at: nil} = reload(other_operation)
    assert [%{state: :submitted}] = attempts(other_operation)
  end

  # The browser's press, recorded before the wallet opens; it never reports.
  defp press(operation) do
    WalletAttempt
    |> Ash.Changeset.for_create(
      :dispatch,
      %{
        launch_operation_id: operation.id,
        step: :launch,
        envelope: operation.envelope,
        state: :dispatched
      },
      actor: @actor
    )
    |> Ash.create(actor: @actor)
  end

  # One reviewed launch, as `prepare_launch` stores it for `account`.
  defp review!(account, draft, signer) do
    deployment = Lab.current!()
    factory = Lab.address!(deployment, :factory)

    envelope = %{
      "chain_id" => deployment.chain_id,
      "expected_signer" => signer,
      "expires_at" => DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601(),
      "arguments" => %{
        "steps" => [%{"step" => "launch", "to" => factory, "data" => "0x"}],
        "name" => "Open Research",
        "symbol" => "OPEN",
        "description" => "A launch profile awaiting review.",
        "website" => "https://example.test/open",
        "image" => nil,
        "regent" => Abi.regent_address(),
        "required_regent_raised_atomic" => "1000",
        "factory" => factory,
        "treasury" => LaunchFixture.treasury()
      },
      "metadata" => %{"lab" => %{"addresses" => %{"hook" => LaunchFixture.hook()}}}
    }

    LaunchOperation
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        action_id: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        envelope: envelope,
        signer: signer,
        step: :launch,
        human_account_id: account.id,
        launch_draft_id: draft.id
      },
      actor: @actor
    )
    |> Ash.create!(actor: @actor)
  end

  # The ledger stores the factory's `LaunchCreated` for this transaction.
  defp record_launch(launcher) do
    factory = Lab.address!(Lab.current!(), :factory)

    :ok =
      LaunchProjection.project_logs([
        %{
          address: factory,
          transaction_hash: @hash,
          topics: [
            LaunchAbi.selector(:launch_created),
            word(7),
            address_word(launcher),
            address_word(@subject)
          ],
          data:
            "0x" <>
              Enum.map_join(
                [
                  address_word(@auction),
                  address_word(@escrow),
                  address_word(LaunchFixture.treasury()),
                  word(1_000),
                  word(30_001_800),
                  word(30_088_201)
                ],
                &String.trim_leading(&1, "0x")
              )
        }
      ])
  end

  defp run_triggers,
    do: AshOban.Test.schedule_and_run_triggers(LaunchDiscovery, actor: @actor)

  defp discoveries, do: Ash.read!(LaunchDiscovery, actor: @actor)

  defp auctions,
    do: Ash.read!(Auction, actor: @actor)

  defp reload(operation),
    do: LaunchOperation |> Ash.Query.filter(id == ^operation.id) |> Ash.read_one!(actor: @actor)

  defp attempts(operation),
    do:
      WalletAttempt
      |> Ash.Query.filter(launch_operation_id == ^operation.id)
      |> Ash.read!(actor: @actor)

  defp word(number),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(number, 16)), 64, "0")

  defp address_word("0x" <> hex), do: "0x" <> String.pad_leading(String.downcase(hex), 64, "0")
end
