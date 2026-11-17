defmodule AutolaunchWeb.AccountAnswer do
  @moduledoc """
  A paired agent's private reads and its launch draft saves, for the person it
  acts for: the draft of each kind and its save, the person's bids and
  holdings, and their Points. Each answer is the whole JSON document its
  signed route sends (`AutolaunchWeb.AgentAccountController`), whose `data` its
  hosted MCP tool gives, Points' whole (`Autolaunch.AgentAccount`), or the
  refusal both give (`AutolaunchWeb.Refusal`). The bids and holdings are also
  what a person signed in on this site reads
  (`AutolaunchWeb.MyPositionsController`).
  Nothing here holds a wallet, signs or launches: the person reviews a draft
  and signs its launch on the create page.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.{Agent, Human, System}
  alias Autolaunch.{AgentDrafts, AuctionBook, SharedReading, TokenHoldings}
  alias Autolaunch.Points.Board
  alias Autolaunch.Robinhood.Positions, as: RobinhoodPositions
  alias AutolaunchWeb.{BidSettlementComponent, Paths, PointsEntries, PublicDocuments}
  alias AutolaunchWeb.{ReadFailure, Refusal}
  alias RegentChain.Address
  alias RegentPoints.Rules

  @points_off "Earning Points is off on this site."
  @read_ms 30_000

  @doc "The person's draft of `kind`, null before there is one."
  def draft(kind, %Agent{} = actor) do
    case AgentDrafts.read(kind, actor) do
      {:ok, draft} -> {:ok, %{data: AgentDrafts.present(draft), kind: kind}}
      _unavailable -> account_unavailable()
    end
  end

  @doc """
  Saves `params`, the route's body, on the person's draft of `kind`: everything
  the person's create form takes. The person still reviews and signs the launch
  (`Autolaunch.AgentDrafts`).
  """
  def save_draft(kind, params, %Agent{} = actor) do
    case AgentDrafts.save(kind, params, actor) do
      {:ok, draft} ->
        {:ok, %{data: AgentDrafts.present(draft), kind: kind}}

      {:error, :invalid_image} ->
        {:error,
         Refusal.new(
           :unprocessable_entity,
           "invalid_image",
           "Send the picture as a PNG, JPEG or WebP file, base64 in image.data with its image.content_type."
         )}

      {:error, :image_too_large} ->
        {:error,
         Refusal.new(
           :unprocessable_entity,
           "image_too_large",
           "The picture is larger than 2 MB, or more than 4096 by 4096 pixels."
         )}

      {:error, _invalid} ->
        invalid_draft()
    end
  end

  @doc "The refusal for a draft save the route would not take."
  def invalid_draft,
    do:
      {:error,
       Refusal.new(
         :unprocessable_entity,
         "invalid_draft",
         "The draft was not saved. Send only the draft's own fields, each as text, and check your current pairing."
       )}

  @doc """
  A hosted draft save's input as its route's body: each field given, by its
  name, a choice as its text; a picture given as null is no picture, as on the
  route.
  """
  def draft_params(arguments),
    do: Map.new(arguments, fn {name, value} -> {Atom.to_string(name), field(value)} end)

  defp field(nil), do: nil
  defp field(value) when is_atom(value), do: Atom.to_string(value)
  defp field(value), do: value

  @doc "The person's Points: their summary, the shared board and, while no rule earns, a note saying so."
  def points(%Agent{} = actor) do
    with {:ok, summary} <- RegentPoints.summary(actor: actor),
         {:ok, %{reading: %{} = board}} <- SharedReading.fetch(Board.key()) do
      earning = Rules.active()
      answer = PointsEntries.answer(summary, board, actor.human_account_id, earning != [])
      {:ok, with_note(answer, earning == [], @points_off)}
    else
      _unavailable -> account_unavailable()
    end
  end

  defp with_note(answer, true, note), do: Map.put(answer, :note, note)
  defp with_note(answer, false, _note), do: answer

  @doc """
  The bids and holdings of the person a paired agent acts for, read from the
  account its pairing names, as the signed route reads it
  (`AutolaunchWeb.Plugs.AgentAccess`).
  """
  def positions(%Agent{privy_user_id: privy_user_id} = actor) do
    case Accounts.get_by_privy_did(privy_user_id, actor: %System{}) do
      {:ok, %{} = account} ->
        positions(actor, account)

      {:ok, nil} ->
        account_unavailable()

      {:error, error} ->
        ReadFailure.log("agent's person read", error)
        account_unavailable()
    end
  end

  @doc """
  The bids and holdings of `account`'s one signed-in wallet, read now from the
  site's records and the chain; a read that fails refuses the whole answer
  rather than leave part of it out. An agent's person may have signed in
  without a wallet; then there is no wallet to read.
  """
  def positions(%Agent{} = actor, account) do
    if VerifiedSession.current?(account),
      do: wallet_positions(actor, account),
      else:
        {:error,
         Refusal.new(
           :conflict,
           "wallet_required",
           "Your person's Regent account has no verified wallet to read."
         )}
  end

  def positions(%Human{} = actor, account), do: wallet_positions(actor, account)

  defp wallet_positions(actor, account) do
    {:ok, wallet} = Address.normalize(account.wallet_address)

    reads = [
      fn -> read_bids(actor, wallet) end,
      fn -> RobinhoodPositions.read_wallet(wallet) end,
      fn -> TokenHoldings.read_wallet(actor, wallet) end
    ]

    results =
      Autolaunch.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(reads, & &1.(),
        timeout: @read_ms,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    case results do
      [{:ok, {:ok, base}}, {:ok, {:ok, robinhood}}, {:ok, {:ok, holdings}}] ->
        books = books(base)

        {:ok,
         %{
           data: %{
             bids: Enum.map(base, &base_bid(&1, books)) ++ Enum.map(robinhood, &robinhood_bid/1),
             tokens: Enum.map(holdings, &token/1)
           }
         }}

      _unavailable ->
        {:error,
         Refusal.new(
           :service_unavailable,
           "chain_unavailable",
           "Your bids and tokens could not be read just now."
         )}
    end
  end

  defp account_unavailable,
    do:
      {:error,
       Refusal.new(
         :service_unavailable,
         "account_unavailable",
         "Account data is unavailable; nothing was changed."
       )}

  defp read_bids(%Agent{} = actor, wallet) do
    Autolaunch.Bid
    |> Ash.Query.for_read(:agent_mine_by_wallet, %{wallet_address: wallet}, actor: actor)
    |> Ash.read()
  end

  defp read_bids(actor, wallet), do: Autolaunch.list_wallet_bid_positions([wallet], actor: actor)

  # The price books of the auctions still taking bids that the Base bids are
  # in; a book that cannot be read leaves its bids' standing unread.
  defp books(positions) do
    auctions =
      for %{status: :active, auction: %{state: :active} = auction} <- positions,
          uniq: true,
          do: auction

    for auction <- auctions,
        {:ok, book} <- [AuctionBook.base(auction)],
        into: %{},
        do: {auction.id, book}
  end

  defp base_bid(position, books) do
    auction = position.auction
    {standing, can} = base_standing(position, Map.get(books, auction.id))

    %{
      bid: position.bid_id,
      chain: "base",
      name: auction.title,
      symbol: auction.token_symbol,
      currency: auction.quote_token_symbol,
      amount: position.amount,
      max_price: position.max_price,
      standing: standing,
      can: can,
      page: PublicDocuments.url(Paths.auction(auction)),
      bid_page: PublicDocuments.url(Paths.bid(position.bid_id))
    }
  end

  defp base_standing(%{status: :active, auction: %{state: :active}}, nil),
    do: {"bidding_open", nil}

  defp base_standing(%{status: :active, auction: %{state: :active} = auction} = position, book),
    do: live_standing(AuctionBook.bid_standing(position, auction, book))

  defp base_standing(%{status: :active}, _book), do: {"bidding_ended", nil}

  defp base_standing(%{status: :returnable} = position, _book) do
    if BidSettlementComponent.spent?(position),
      do: {"claim_ready", "claim"},
      else: {"withdraw_ready", "withdraw"}
  end

  defp base_standing(%{status: :claimable}, _book), do: {"claim_ready", "claim"}

  defp base_standing(%{status: :awaiting_claim}, _book), do: {"claim_later", nil}

  defp base_standing(_settled, _book), do: {"done", nil}

  defp robinhood_bid(position) do
    {standing, can} = robinhood_standing(position.standing)
    bid = String.downcase("#{position.auction}:#{position.bid_id}")

    %{
      bid: bid,
      chain: "robinhood",
      name: position.name,
      symbol: position.symbol,
      currency: position.stock_symbol,
      amount: position.committed,
      max_price: position.max_price,
      standing: standing,
      can: can,
      page: position.listing && PublicDocuments.url(Paths.auction(position.listing)),
      bid_page: PublicDocuments.url(Paths.bid(bid))
    }
  end

  defp robinhood_standing(standing) when standing in [:in, :sharing, :outbid],
    do: live_standing(standing)

  defp robinhood_standing(:ended), do: {"bidding_ended", nil}

  defp robinhood_standing(standing) when standing in [:refundable, :graduated],
    do: {"withdraw_ready", "withdraw"}

  defp robinhood_standing(:filled), do: {"claim_later", nil}
  defp robinhood_standing(:claimable), do: {"claim_ready", "claim"}
  defp robinhood_standing(_settled), do: {"done", nil}

  # A bid while bidding is open, against the auction's price. One that is not
  # buying may take its unspent money back early; its card says when.
  defp live_standing(:in), do: {"buying", nil}
  defp live_standing(:sharing), do: {"sharing_price", "early_return"}
  defp live_standing(:outbid), do: {"outbid", "early_return"}

  defp token(holding) do
    %{
      name: holding.name,
      symbol: holding.symbol,
      chain: Atom.to_string(holding.chain),
      held: holding.held,
      staked: holding.staked,
      claimable: holding.claimable,
      page: holding.token && PublicDocuments.url(Paths.token(holding.token.auction))
    }
  end
end
