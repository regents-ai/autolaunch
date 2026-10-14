defmodule AutolaunchWeb.LiveSettle do
  @moduledoc """
  A list page's own Claim, Withdraw and Refund buttons: the signed-in wallet's
  ended Base bids with money or tokens to take, one for each auction
  (`settle`, by auction id, with the few words on each button in
  `settle_labels`), and the settlement card a press opens in the page's one
  dialog (`trade`, as `%{position: bid}`). `settle_column` says
  whether the viewer has had such a button this visit, so a list that makes
  room for one keeps that room after the last is taken.

  The page calls `watch/1` in its mount, after `AutolaunchWeb.LiveListings.subscribe/1`
  and with `trade` assigned, hands `settle_labels` to its list and draws the card
  for a `trade` that holds a position. Everything else happens here:

    * "open_settlement" opens the pressed auction's bid, and "close_trade"
      closes it;
    * the bids are read again with the page's next reread of its listings
      after one of the wallet's bids is written (`Autolaunch.WalletBids`) or
      an auction it has a bid to settle in changes, and at once when the open
      card verifies a step.

  Signed out there is nothing to read, and `settle` stays empty.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [human_actor: 1, signed_in_wallet: 1]

  alias AutolaunchWeb.{BidSettlementComponent, LiveListings}

  def watch(socket) do
    wallet = signed_in_wallet(socket.assigns.access_context)
    if wallet && connected?(socket), do: Autolaunch.WalletBids.subscribe(wallet)

    socket
    |> assign(:settle, %{})
    |> assign(:settle_labels, %{})
    |> assign(:settle_column, false)
    |> assign(:settle_due, false)
    |> attach_hook(:settle_event, :handle_event, &event/3)
    |> attach_hook(:settle_info, :handle_info, &info/2)
    |> read()
  end

  defp event("open_settlement", %{"id" => id}, socket) do
    trade =
      case socket.assigns.settle do
        %{^id => position} -> %{position: position}
        _none -> nil
      end

    {:halt, assign(socket, :trade, trade)}
  end

  # Another dialog of the page's is the page's own to close.
  defp event("close_trade", _params, %{assigns: %{trade: %{record: _}}} = socket),
    do: {:cont, socket}

  defp event("close_trade", params, socket) do
    case {params, socket.assigns.trade} do
      {%{"id" => id}, %{position: %{id: id}}} -> {:halt, assign(socket, :trade, nil)}
      _another_card_or_none -> {:halt, socket}
    end
  end

  defp event(_event, _params, socket), do: {:cont, socket}

  # A bid's button is worded by its auction's outcome, so a change to an
  # auction the viewer has a bid to settle in reads that bid again too.
  defp info({:autolaunch_listings_changed, auction_id}, socket)
       when is_map_key(socket.assigns.settle, auction_id),
       do: {:cont, assign(socket, :settle_due, true)}

  # One of the viewer's bids was written: its auction ended, or its tokens
  # became claimable. Read with the listing's next reread, after the write
  # has landed.
  defp info({:autolaunch_bid_changed, _bid_id}, socket),
    do: {:halt, socket |> assign(:settle_due, true) |> LiveListings.schedule()}

  # The open settlement card verified a step, so the stored bid changed.
  defp info({:bid_settlement_changed, _position_id}, socket), do: {:halt, read(socket)}

  defp info(:reread_listings, %{assigns: %{settle_due: true}} = socket),
    do: {:cont, socket |> assign(:settle_due, false) |> read()}

  defp info(_message, socket), do: {:cont, socket}

  # A read that fails leaves the buttons the viewer already has. An open card
  # follows its bid, which leaves this list once it has nothing left to take.
  defp read(socket) do
    context = socket.assigns.access_context

    with %{} = actor <- human_actor(context),
         {:ok, positions} <-
           Autolaunch.list_wallet_bids_to_settle(signed_in_wallet(context), actor: actor) do
      settle = Map.new(Enum.reverse(positions), &{&1.auction_id, &1})

      socket
      |> assign(:settle, settle)
      |> assign(:settle_labels, Map.new(settle, &label/1))
      |> assign(:settle_column, socket.assigns.settle_column or positions != [])
      |> follow_open_bid(actor)
    else
      _signed_out_or_unread -> socket
    end
  end

  defp label({auction_id, position}),
    do: {auction_id, BidSettlementComponent.settle_label(position)}

  defp follow_open_bid(%{assigns: %{trade: %{position: %{bid_id: bid_id}}}} = socket, actor) do
    case Autolaunch.get_my_bid_position(bid_id, actor: actor) do
      {:ok, %Autolaunch.Bid{} = position} -> assign(socket, :trade, %{position: position})
      _unread -> socket
    end
  end

  defp follow_open_bid(socket, _actor), do: socket
end
