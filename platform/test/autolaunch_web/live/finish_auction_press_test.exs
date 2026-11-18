defmodule AutolaunchWeb.FinishAuctionPressTest do
  @moduledoc """
  A Finish press made while the card holds no reading of the launch still
  reaches the wallet: the card reads the launch for the press and hands back
  the finish to send, as a settlement press does
  (`AutolaunchWeb.BidSettlementComponent`). A launch the chain already shows
  finished hands back nothing. The wallet's button is held, disabled with the
  block finishing opens at, only while even the launchpad clock's next step is
  before the migration block; one step before it, the finish is offered and
  sent, on a Base Revstake and a Base Memestock launchpad and on Robinhood
  Chain, whose clock is not the block. A held card reads the launch again as
  the site reads a new block, and offers the finish once that block is one
  before the migration block. An auction whose launchpad holds no launch is
  held and never read again.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, BidFixture, Lab, LabAbi, RobinhoodBidChain}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.BuilderCode

  @running 1
  @graduated 2
  @migration_block 90
  # A Base Memestock launch's id on its launchpad.
  @launch_id 4
  # Robinhood Chain's launch finishes from rollup block 95, read at block 100
  # (`Autolaunch.RobinhoodBidChain`), and is the launchpad's launch 1.
  @robinhood_migration 95
  @robinhood_launch_id 1

  setup :bidder

  # The card as an ended auction's page holds it, for a signed-in person, given
  # the newest block the site has read on the auction's chain as the page
  # passes it (`Autolaunch.ChainHead`).
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
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id),
         observed: nil
       )}
    end

    def handle_info({:observed, block}, socket), do: {:noreply, assign(socket, observed: block)}

    # Robinhood Chain's double tells the process reading it of each read, as a
    # press's read is made here.
    def handle_info({:robinhood_read, _method}, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.FinishAuctionComponent}
        id="card"
        auction={@auction}
        observed={@observed}
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
    assert offered?(view)
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
    assert held?(view)
  end

  # FINISH_HELD_ONE_BLOCK_TOO_LONG: `migrate` reverts only while the
  # launchpad's clock is before the migration block, and a finish sent at the
  # latest block lands in the next one or later, so the card held the button
  # one block longer than a finish sent then would revert.
  test "FINISH_HELD_ONE_BLOCK_TOO_LONG: two blocks before the migration block the button is held with the block it opens at, and nothing is sent",
       %{conn: conn} = context do
    {view, card, _auction} = card(conn, context, %{latest: @migration_block - 2})
    html = render(view)

    assert html =~ "Finishing opens at block #{@migration_block}."
    refute html =~ "Ready to finish."
    assert held?(view)

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
    assert offered?(view)

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})
    {:ok, config} = Lab.contracts(Lab.current!(), auction.contracts_version)
    strategy = Lab.address!(config, :strategy)
    assert_reply(view, %{send: "finish", review: %{steps: [%{step: "finish", to: ^strategy}]}})
  end

  test "FINISH_HELD_ONE_BLOCK_TOO_LONG: on a Base Memestock launchpad and on Robinhood Chain, whose clock is not the block, two steps before the migration block the button is held and one step before it the launchpad's own finish is sent",
       %{conn: conn} = context do
    {:ok, stocks} = StocksLab.contracts(StocksLab.current!(), :v2)
    RobinhoodBidChain.install()
    {:ok, config} = RobinhoodLab.current()
    {:ok, robinhood} = RobinhoodLab.contracts(config, :v2)

    for {name, open, opens_at, launchpad, launch_id} <- [
          {"Base Memestock", &memestock_card(conn, context, &1), @migration_block, stocks,
           @launch_id},
          {"Robinhood Chain", &robinhood_card(conn, context, &1), @robinhood_migration, robinhood,
           @robinhood_launch_id}
        ] do
      {view, card, _auction} = open.(opens_at - 2)

      assert render(view) =~ "Finishing opens at block #{opens_at}.", "#{name} two before"
      assert held?(view), "#{name} two before"

      render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})
      assert_reply(view, reply)
      assert reply == %{}, "#{name} two before"

      {view, card, _auction} = open.(opens_at - 1)

      assert render(view) =~ "Ready to finish.", "#{name} one before"
      assert offered?(view), "#{name} one before"

      render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})
      to = launchpad.launchpad

      data =
        launchpad.abis["launchpad"]
        |> LabAbi.encode("migrate(uint256)", [launch_id])
        |> BuilderCode.append()

      assert_reply(view, %{send: "finish", review: %{steps: [%{to: ^to, data: ^data}]}})
    end
  end

  test "a held card reads the launch again as the site reads a new block, and offers the finish once that block is one before the migration block",
       %{conn: conn} = context do
    {view, _card, _auction} = card(conn, context, %{latest: @migration_block - 2})
    assert held?(view)

    BaseRpcStub.put(%{blocks: %{"latest" => block(@migration_block - 1)}})
    send(view.pid, {:observed, @migration_block - 1})
    render_async(view)

    assert render(view) =~ "Ready to finish."
    assert offered?(view)
  end

  test "an auction whose launchpad holds no launch says so with the button disabled; a press sends nothing and the card stays, and no new block reads it again",
       %{conn: conn} = context do
    # Revstake's strategy answers an all-zero distribution for an address that
    # is no auction of its own.
    {view, card, _auction} = card(conn, context, %{latest: @migration_block - 1, lifecycle: 0})
    assert render(view) =~ "This auction has no launch to finish."
    assert held?(view)
    BaseRpcStub.call_blocks()

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "finish"})
    assert_reply(view, reply)
    assert reply == %{}

    for block <- [@migration_block, @migration_block + 1] do
      send(view.pid, {:observed, block})
      render_async(view)
    end

    assert render(view) =~ "This auction has no launch to finish."
    assert held?(view)
    refute_received {:rpc, _method, _params}
  end

  # The wallet's own Finish button, shown and pressable: it names the finish
  # step the wallet sends.
  defp offered?(view),
    do:
      has_element?(
        view,
        ~s|#card button.token-swap__wallet-step[data-onchain-step="finish"]:not([hidden]):not([disabled])|
      )

  # The Finish button held: shown and disabled, and no button that sends.
  defp held?(view),
    do:
      has_element?(
        view,
        "#card button.token-swap__submit[disabled]:not([hidden])",
        "Finish auction"
      ) and
        not has_element?(view, "#card [data-onchain-step]") and
        not has_element?(view, "#card button.token-swap__wallet-step:not([hidden])")

  # The card of an ended Base auction, a Revstake one unless `fields` name
  # another, opened by a signed-in person with their wallet active. By default
  # the chain did not answer its first reading of the launch; with `latest`,
  # the chain answers it at that block, the launch running unless `lifecycle`
  # says otherwise.
  defp card(conn, context, chain \\ %{answers?: false}, fields \\ []) do
    auction =
      ended_auction(
        context,
        Keyword.merge([chain_id: Lab.chain_id(), address: BidFixture.auction_address()], fields)
      )

    BaseRpcStub.install(:autolaunch_lab_http_client, &answer/2)
    {latest, chain} = Map.pop(chain, :latest, 100)

    BaseRpcStub.put(
      Map.merge(
        %{
          answers?: true,
          lifecycle: @running,
          version: auction.contracts_version,
          auction: auction.auction_address,
          blocks: %{"latest" => block(latest)}
        },
        chain
      )
    )

    open(conn, context, auction)
  end

  # The card of an ended Base Memestock auction, read at the latest block `latest`.
  defp memestock_card(conn, context, latest),
    do: card(conn, context, %{latest: latest}, kind: :stocks, address: nil)

  # The card of an ended Robinhood Chain auction, its launchpad's clock at
  # `clock` while the latest block is 100.
  defp robinhood_card(conn, context, clock) do
    RobinhoodBidChain.install(%{clock: clock})

    auction =
      ended_auction(context,
        chain_id: RobinhoodBidChain.chain_id(),
        kind: :stocks,
        address: RobinhoodBidChain.auction()
      )

    open(conn, context, auction)
  end

  defp ended_auction(context, fields) do
    [
      title: context.auction.title,
      featured: false,
      state: :ended,
      opened_at: ~U[2026-08-20 11:00:00Z]
    ]
    |> Keyword.merge(fields)
    |> Autolaunch.TestSupport.project_auction()
  end

  defp open(conn, context, auction) do
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

  defp block(number),
    do: %{
      "number" => "0x" <> Integer.to_string(number, 16),
      "hash" => BaseRpcStub.safe_hash(),
      "timestamp" => "0x6700"
    }

  # Base's answer to a launch's record: the Revstake strategy's distribution of
  # the auction, or the Memestock launchpad's launch id and its launch naming
  # the auction, each holding the state's lifecycle and the migration block.
  defp answer(_call, %{answers?: false}), do: :unavailable

  defp answer(%{data: data}, state) do
    cond do
      called?(data, "distribution(address)") ->
        List.duplicate(0, LabAbi.distribution_words())
        |> List.replace_at(0, state.lifecycle)
        |> List.replace_at(4, @migration_block)
        |> words()

      called?(data, "launchIdOfAuction(address)") ->
        BaseRpcStub.uint(@launch_id)

      called?(data, "launches(uint256)") ->
        "0x" <> auction = state.auction

        held = %{
          lifecycle: state.lifecycle,
          migration_block: @migration_block,
          auction: String.to_integer(auction, 16)
        }

        StocksLabAbi.shape(state.version).record_fields
        |> Enum.map(&Map.get(held, &1, 0))
        |> words()
    end
  end

  defp called?(data, signature), do: String.starts_with?(data, LabAbi.selector(signature))

  defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)
end
