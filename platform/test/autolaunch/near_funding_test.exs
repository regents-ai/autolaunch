defmodule Autolaunch.NearFundingTest do
  @moduledoc """
  A NEAR funding against the 1Click service's recorded answers
  (`Autolaunch.TestNearIntents`): the USDC always goes to the acting account's
  own signed-in wallet, a funding is read only by its own account, and its
  status job follows the swap until it ends, broadcasting each change.
  """
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  alias Autolaunch.Actors.{Agent, Human, System}
  alias Autolaunch.{Funding, NearFunding, TestNearIntents, TestSupport}

  @moduletag :capture_log
  @usdc 5_000_000

  # A start queues its status job; no queue runs under ExUnit.
  setup do
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    TestNearIntents.install()
    auction = TestSupport.project_auction(state: :active)
    {account, wallet} = account()
    %{auction: auction, actor: %Human{human_account_id: account.id}, wallet: wallet}
  end

  defp account do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    other = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    privy = "did:privy:near-#{:erlang.unique_integer([:positive])}"

    {Autolaunch.Accounts.register_verified!(privy, wallet, [wallet, other], actor: %System{}),
     wallet}
  end

  defp reason({:error, error}), do: Funding.reason(error)

  test "a quote prices the USDC in NEAR for the account's own wallet and stores nothing", %{
    auction: auction,
    actor: actor,
    wallet: wallet
  } do
    assert {:ok, quote} = Funding.quote_near_funding(auction.id, @usdc, actor: actor)

    assert quote == %{
             usdc_amount: @usdc,
             near_amount: "1.652",
             near_amount_raw: "1651313840569386417635746",
             time_estimate_s: 24,
             recipient: wallet
           }

    assert [%{dry: true, recipient: ^wallet, usdc_amount: @usdc}] = TestNearIntents.state().asked
    assert Ash.read!(NearFunding, actor: %System{}) == []
  end

  test "a quote or start is refused for an unknown auction, a bad amount or refund account, or a silent service",
       %{auction: auction, actor: actor} do
    assert :unknown_auction =
             reason(Funding.quote_near_funding(Ash.UUID.generate(), @usdc, actor: actor))

    assert :unknown_auction = reason(Funding.quote_near_funding("not-an-id", @usdc, actor: actor))
    assert :invalid_amount = reason(Funding.quote_near_funding(auction.id, 0, actor: actor))

    assert :invalid_refund_account =
             reason(Funding.start_near_funding(auction.id, @usdc, "Not A Name!", actor: actor))

    TestNearIntents.put(%{unavailable: true})
    assert :near_unavailable = reason(Funding.quote_near_funding(auction.id, @usdc, actor: actor))

    assert :near_unavailable =
             reason(Funding.start_near_funding(auction.id, @usdc, "sean.near", actor: actor))

    assert Ash.read!(NearFunding, actor: %System{}) == []
  end

  test "an account with no wallet to act with is refused", %{auction: auction} do
    privy = "did:privy:near-none-#{:erlang.unique_integer([:positive])}"
    account = Autolaunch.Accounts.register_verified!(privy, nil, [], actor: %System{})
    actor = %Human{human_account_id: account.id}

    assert :wallet_required = reason(Funding.quote_near_funding(auction.id, @usdc, actor: actor))
  end

  test "starting stores the deposit address for the account's own wallet and queues its status job",
       %{auction: auction, actor: actor, wallet: wallet} do
    assert {:ok, funding} =
             Funding.start_near_funding(auction.id, @usdc, " sean.near ", actor: actor)

    assert %NearFunding{
             human_account_id: id,
             recipient: ^wallet,
             refund_to: "sean.near",
             usdc_amount: @usdc,
             near_amount: "1.652",
             state: :pending_deposit,
             origin_tx: nil
           } = funding

    assert id == actor.human_account_id
    assert funding.deposit_address == TestNearIntents.deposit_address()

    assert [%{dry: false, recipient: ^wallet, refund_to: "sean.near"}] =
             TestNearIntents.state().asked

    assert_enqueued(worker: NearFunding.Watch, args: %{id: funding.id})

    id = funding.id
    assert {:ok, %{id: ^id}} = Funding.near_funding(id, actor: actor)
    assert {:ok, [%{id: ^id}]} = Funding.near_fundings_for(auction.id, actor: actor)
  end

  test "a funding is read only by its own account, a person or their paired agent", %{
    auction: auction,
    actor: actor,
    wallet: wallet
  } do
    {:ok, funding} = Funding.start_near_funding(auction.id, @usdc, "sean.near", actor: actor)
    {stranger, _wallet} = account()
    stranger = %Human{human_account_id: stranger.id}

    assert {:error, %Ash.Error.Invalid{}} = Funding.near_funding(funding.id, actor: stranger)
    assert {:ok, []} = Funding.near_fundings_for(auction.id, actor: stranger)
    assert {:error, _not_found} = Funding.refresh_near_funding(funding.id, actor: stranger)
    assert {:error, _forbidden} = Funding.refresh_near_funding(funding, actor: stranger)

    agent = %Agent{
      wallet_address: "0x" <> String.duplicate("a", 40),
      privy_user_id: "did:privy:agent",
      pairing_id: Ash.UUID.generate(),
      human_account_id: actor.human_account_id
    }

    assert {:ok, %{id: id}} = Funding.near_funding(funding.id, actor: agent)
    assert id == funding.id
    assert {:ok, quote} = Funding.quote_near_funding(auction.id, @usdc, actor: agent)
    assert quote.recipient == wallet
  end

  test "the status job follows the swap to success, broadcasting each change", %{
    auction: auction,
    actor: actor
  } do
    {:ok, funding} = Funding.start_near_funding(auction.id, @usdc, "sean.near", actor: actor)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, "near_funding:#{funding.id}")

    assert {:snooze, 10} = perform_job(NearFunding.Watch, %{id: funding.id})
    refute_received {:near_funding, _funding}

    TestNearIntents.put(%{
      status: %{state: :processing, origin_tx: "near-tx", destination_tx: nil}
    })

    assert {:snooze, 10} = perform_job(NearFunding.Watch, %{id: funding.id})
    assert_received {:near_funding, %{state: :processing, origin_tx: "near-tx"}}

    TestNearIntents.put(%{
      status: %{state: :success, origin_tx: "near-tx", destination_tx: "0xbase"}
    })

    assert :ok = perform_job(NearFunding.Watch, %{id: funding.id})
    assert_received {:near_funding, %{state: :success, destination_tx: "0xbase"}}

    assert {:ok, %{state: :success}} = Funding.near_funding(funding.id, actor: actor)
  end

  test "a swap refunded ends the job; a silent service retries it; a long-gone deadline stops it",
       %{auction: auction, actor: actor} do
    {:ok, funding} = Funding.start_near_funding(auction.id, @usdc, "sean.near", actor: actor)

    TestNearIntents.put(%{unavailable: true})
    assert {:error, _unread} = perform_job(NearFunding.Watch, %{id: funding.id})
    TestNearIntents.put(%{unavailable: false})

    TestNearIntents.put(%{status: %{state: :refunded, origin_tx: "near-tx", destination_tx: nil}})
    assert {:ok, %{state: :refunded}} = Funding.refresh_near_funding(funding, actor: actor)
    assert :ok = perform_job(NearFunding.Watch, %{id: funding.id})

    TestNearIntents.put(%{
      deadline_in: -16 * 60,
      status: %{state: :pending_deposit, origin_tx: nil, destination_tx: nil}
    })

    {:ok, late} = Funding.start_near_funding(auction.id, @usdc, "sean.near", actor: actor)

    assert :ok = perform_job(NearFunding.Watch, %{id: late.id})
  end
end
