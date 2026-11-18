defmodule AutolaunchWeb.FinishAuctionPressTest do
  @moduledoc """
  A Finish press made while the card holds no reading of the launch still
  reaches the wallet: the card reads the launch for the press and hands back
  the finish to send, as a settlement press does
  (`AutolaunchWeb.BidSettlementComponent`). A launch the chain already shows
  finished hands back nothing. The button is held, with the block finishing
  opens at, only while even the next block is before the migration block; one
  block before it, the finish is offered and sent.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, BidFixture, Lab, LabAbi}
  alias RegentChain.BuilderCode

  @running 1
  @graduated 2
  @migration_block 90

  setup :bidder

  # The card as an ended auction's page holds it, for a signed-in person.
  defmodule Card do
    use Phoenix.LiveView

    def mount(_params, %{"auction_id" => auction_id, "account_id" => account_id}, socket) do
      {:ok, auction} =
        Ash.get(Autolaunch.Auction, auction_id,
          action: :market,
          actor: %Autolaunch.Actors.System{}
        )

      {:ok,
       assign(socket,
         auction: auction,
         account_id: account_id,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.FinishAuctionComponent}
        id="card"
        auction={@auction}
        observed={nil}
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  # FINISH_PRESS_BEFORE_READING_SENDS: the card's button names the finish before
  # the card has read the launch, and a press then sent nothing, so the auction
  # stayed ended (the agent journeys on a busy machine, 12 Nov 2026).
  test "FINISH_PRESS_BEFORE_READING_SENDS: a Finish press with no reading on the card is read and sent",
       %{conn: conn} = context do
    {view, card, auction} = card(conn, context)
    BaseRpcStub.put(%{answers?: true, lifecycle: @running})

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})

    # The strategy of the launch's own contracts version.
    {:ok, config} = Lab.contracts(Lab.current!(), auction.contracts_version)
    strategy = Lab.address!(config, :strategy)
    wallet = context.wallet

    assert_reply(view, %{
      send: "finish",
      review: %{signer: ^wallet, steps: [%{step: "finish", to: ^strategy, data: data}]}
    })

    assert data ==
             Lab.abi!(config, :strategy)
             |> LabAbi.encode("migrate(address)", [BidFixture.auction_address()])
             |> BuilderCode.append()
  end

  test "a Finish press on a launch the chain shows finished sends nothing",
       %{conn: conn} = context do
    {view, card, _auction} = card(conn, context)
    BaseRpcStub.put(%{answers?: true, lifecycle: @graduated})

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})

    assert_reply(view, reply)
    assert reply == %{}
  end

  # FINISH_HELD_ONE_BLOCK_TOO_LONG: `migrate` reverts only while the
  # launchpad's clock is before the migration block, and a finish sent at the
  # latest block lands in the next one or later, so the card held the button
  # one block longer than the finish was certain to fail.
  test "FINISH_HELD_ONE_BLOCK_TOO_LONG: two blocks before the migration block the button is held with the block it opens at, and nothing is sent",
       %{conn: conn} = context do
    {view, card, _auction} = card(conn, context, %{latest: @migration_block - 2})
    html = render(view)

    assert html =~ "Finishing opens at block #{@migration_block}."
    refute html =~ "Ready to finish."

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})
    assert_reply(view, reply)
    assert reply == %{}
  end

  test "FINISH_HELD_ONE_BLOCK_TOO_LONG: one block before the migration block the finish is offered and sent",
       %{conn: conn} = context do
    {view, card, auction} = card(conn, context, %{latest: @migration_block - 1})
    html = render(view)

    assert html =~ "Ready to finish."
    refute html =~ "Finishing opens at block"

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})
    {:ok, config} = Lab.contracts(Lab.current!(), auction.contracts_version)
    strategy = Lab.address!(config, :strategy)
    assert_reply(view, %{send: "finish", review: %{steps: [%{step: "finish", to: ^strategy}]}})
  end

  # The card of an ended auction, opened by a signed-in person with their
  # wallet active. By default the chain did not answer its first reading of the
  # launch; with `latest`, the chain answers it at that block, the launch still
  # running.
  defp card(conn, context, chain \\ %{answers?: false}) do
    auction =
      Autolaunch.TestSupport.project_auction(
        address: BidFixture.auction_address(),
        title: context.auction.title,
        featured: false,
        state: :ended,
        opened_at: ~U[2026-08-20 11:00:00Z]
      )

    BaseRpcStub.install(:autolaunch_lab_http_client, &answer/2)
    {latest, chain} = Map.pop(chain, :latest, 100)

    block = %{
      "number" => "0x" <> Integer.to_string(latest, 16),
      "hash" => BaseRpcStub.safe_hash(),
      "timestamp" => "0x6700"
    }

    BaseRpcStub.put(
      Map.merge(%{answers?: true, lifecycle: @running, blocks: %{"latest" => block}}, chain)
    )

    session = signed_in_session(context.account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Card,
        session: %{"auction_id" => auction.id, "account_id" => context.account.id}
      )

    card = with_target(view, "#card")
    render_hook(card, "onchain_active_wallet", %{"address" => context.wallet})
    render_async(view)
    {view, card, auction}
  end

  # The strategy's record of the auction: its migration block, with the
  # lifecycle the test names.
  defp answer(_call, %{answers?: false}), do: :unavailable

  defp answer(_call, %{lifecycle: lifecycle}) do
    words =
      List.duplicate(0, LabAbi.distribution_words())
      |> List.replace_at(0, lifecycle)
      |> List.replace_at(4, @migration_block)

    "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
  end
end
