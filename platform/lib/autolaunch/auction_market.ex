defmodule Autolaunch.AuctionMarket do
  @moduledoc """
  Keeps each auction's row and its reading (`Autolaunch.AuctionReading`)
  current from its own contract. Every auction with a contract on a deployment
  this site describes has one job (`Autolaunch.ChainWatch` makes sure of it):
  Base Revstake and Base Memestock auctions are read with everything their own
  page shows, Robinhood auctions without it, since their page reads the chain
  itself.

  A pass reads the auction at the newest block (`Autolaunch.AuctionMarket.Read`)
  and writes, in one transaction under the auction row's lock: its state, price
  and amount raised, its bidders' positions once it has ended, a graduated
  launch's token and that token's pool price, and its reading. A pass at a
  block no newer than the reading's writes nothing, unless the chain has left
  the reading's block. The reading itself is written only when a figure or the
  page changed, when the page could or could not be read where the last pass
  found otherwise, when the chain left its block, or when it is twenty minutes
  old, so a page hears of it only then and `read_at`
  is never older than that while its auction is read.

  Then the job waits: a second on a lab, five minutes while the auction is
  open, twenty once it has finished. A press that lands on its chain brings it
  forward to ten seconds away (`refresh/1`). A pass the node could not answer
  marks the reading degraded, is one warning line and is read again a minute
  later; any other failure is a fault, tried again a minute later.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [keys: [:auction_id], period: :infinity, states: :incomplete]

  @behaviour Autolaunch.ChainRefresh

  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.AuctionMarket.Read
  alias Autolaunch.AuctionReading.Page

  alias Autolaunch.{
    Auction,
    AuctionReading,
    AuctionTerms,
    ChainRefresh,
    ChainWatch,
    LabPositions,
    LabProjection
  }

  alias Autolaunch.Chain.Rpc

  @actor %System{}
  # The node did not answer, or answered with something that is not a block.
  @unavailable [:chain_unavailable, :invalid_chain_response, :invalid_block_header, :wrong_chain]
  @fresh_s 20 * 60
  # What a page shows from the block it was read at, not from the auction.
  @read_at [:block, :clock]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"auction_id" => id}}) do
    case Ash.get(Auction, id, action: :market, actor: @actor, not_found_error?: false) do
      {:ok, nil} -> {:cancel, :not_found}
      {:ok, auction} -> auction |> read() |> next(auction)
      {:error, error} -> {:error, error}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 60

  # A contract the chain does not hold (a launch mined on another lab run, or
  # one a reorg removed) has no market to read until it does.
  defp next(result, auction) when result in [:ok, {:error, :lab_contract_missing}],
    do: {:snooze, wait_s(auction)}

  defp next({:error, reason}, auction) when reason in @unavailable do
    Logger.warning(
      "Market reading for auction #{auction.id} not read (#{reason}); reading again in a minute"
    )

    with :ok <- degrade(auction.id), do: {:snooze, 60}
  end

  defp next({:error, reason}, _auction), do: {:error, reason}

  defp wait_s(%{chain_id: chain, state: state}) do
    cond do
      Autolaunch.Lab.test_chain?(chain) or Autolaunch.Robinhood.Lab.test_chain?(chain) -> 1
      state in [:graduated, :failed] -> 1_200
      true -> 300
    end
  end

  @doc "Every auction's reading job (`Autolaunch.ChainWatch`)."
  def jobs, do: Enum.map(auctions(Auction), &new(%{auction_id: &1.id}))

  @doc """
  A person's on-chain press on chain `chain_id` landed: every auction on it is
  read ten seconds from now, instead of at its next turn. One already due
  sooner stays as it is.
  """
  # No job runs while the site is read-only before launch (`Autolaunch.Application`).
  @impl ChainRefresh
  def refresh(chain_id) do
    if not Autolaunch.Prelaunch.read_only?() do
      Auction
      |> Ash.Query.filter(chain_id == ^chain_id)
      |> auctions()
      |> Enum.each(&ChainWatch.soon(new(%{auction_id: &1.id})))
    end

    :ok
  end

  # Every auction with a contract on a deployment this site describes.
  defp auctions(query) do
    venues = Read.venues()
    chains = Enum.map(venues, &elem(&1, 0))

    query
    |> Ash.Query.for_read(:market, %{}, actor: @actor)
    |> Ash.Query.filter(chain_id in ^chains and not is_nil(auction_address))
    |> Ash.Query.select([:id, :chain_id, :kind])
    |> Ash.read!()
    |> Enum.filter(&({&1.chain_id, &1.kind} in venues))
  end

  @doc "One pass over `auction`: read, then write what changed."
  def read(auction) do
    with {:ok, venue} <- Read.venue(auction),
         {:ok, head} <- Read.head(venue),
         {:ok, held} <- Autolaunch.get_auction_reading(auction.id, actor: @actor),
         {:ok, displaced?} <- displaced?(held, head.block, venue.opts),
         :ok <- newer(held, head.block, displaced?),
         {:ok, snapshot} <- Read.snapshot(venue, head, auction, ladder(held, displaced?)) do
      write(auction.id, snapshot, displaced?)
    else
      :not_newer -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Whether the chain left the block the held reading was read at: it went
  # back past it, or another block now stands at its number.
  defp displaced?(nil, _block, _opts), do: {:ok, false}

  defp displaced?(%{read_block: read}, %{number: newest}, _opts) when newest < read,
    do: {:ok, true}

  defp displaced?(%{read_block: number, block_hash: hash}, %{number: number, hash: hash}, _opts),
    do: {:ok, false}

  defp displaced?(held, _block, opts) do
    with {:ok, canonical?} <-
           Rpc.canonical?(%{number: held.read_block, hash: held.block_hash}, opts),
         do: {:ok, not canonical?}
  end

  defp newer(nil, _block, _displaced?), do: :ok
  defp newer(_held, _block, true), do: :ok
  defp newer(%{read_block: read}, %{number: newest}, false) when newest > read, do: :ok
  defp newer(_held, _block, false), do: :not_newer

  # The ladder the held page read, for the next walk to start from; none from
  # a block the chain left.
  defp ladder(%{page: %Page{ladder: ladder}}, false), do: ladder
  defp ladder(_held, _displaced?), do: nil

  defp write(auction_id, snapshot, displaced?) do
    Ash.transaction([Auction, AuctionReading], fn ->
      with {:ok, %Auction{} = auction} <-
             Autolaunch.get_lab_market_auction_for_update(auction_id, actor: @actor),
           {:ok, held} <- Autolaunch.get_auction_reading(auction_id, actor: @actor),
           :ok <- newer(held, snapshot.block, displaced?),
           :ok <- project(auction, snapshot),
           :ok <- record(auction_id, held, snapshot, displaced?) do
        :ok
      else
        :not_newer -> :ok
        {:ok, nil} -> Ash.DataLayer.rollback(Auction, :not_found)
        {:error, reason} -> Ash.DataLayer.rollback(Auction, reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The auction row, its bidders' positions and its token. A launch seen
  # graduating becomes a public token in the same transaction, so its pool page
  # exists as soon as the row says so, and the token's price is the pool's from
  # the same reading.
  defp project(auction, snapshot) do
    market = %{
      state: MarketState.join(auction.state, snapshot.state),
      price: snapshot.current_clearing_price,
      minimum_reached: snapshot.minimum_reached,
      currency_raised: snapshot.currency_raised,
      terms: snapshot.terms
    }

    changed? =
      auction.state != market.state or auction.current_clearing_price != market.price or
        auction.minimum_reached != market.minimum_reached or
        AuctionTerms.raised_changed?(auction, market.currency_raised) or
        AuctionTerms.missing?(auction)

    with {:ok, _positions_changed?} <- LabPositions.project(snapshot.positions),
         :ok <- refresh_row(auction, changed?, market),
         {:ok, _price_changed?} <-
           LabProjection.project_token_price(auction.id, snapshot.price_quote),
         do: :ok
  end

  defp refresh_row(_auction, false, _market), do: :ok

  defp refresh_row(auction, true, market) do
    with {:ok, row} <-
           Autolaunch.refresh_lab_market_auction(
             auction,
             market.state,
             market.price,
             AuctionTerms.fields(market),
             actor: @actor
           ),
         do: LabProjection.project_graduated_token(row)
  end

  # A page that could not be read leaves the held one, marked degraded.
  defp record(auction_id, nil, snapshot, _displaced?) do
    %{
      auction_id: auction_id,
      read_block: snapshot.block.number,
      block_hash: snapshot.block.hash,
      read_at: DateTime.utc_now(),
      degraded: snapshot.page == :unread,
      market: snapshot.market,
      page: if(snapshot.page != :unread, do: snapshot.page)
    }
    |> Autolaunch.record_auction_reading(actor: @actor)
    |> written()
  end

  defp record(_auction_id, held, snapshot, displaced?) do
    unread? = snapshot.page == :unread

    with {:ok, page_changed?} <- page_changed?(held.page, snapshot.page) do
      if displaced? or held.degraded != unread? or page_changed? or old?(held) or
           market_changed?(held.market, snapshot.market) do
        held
        |> Autolaunch.refresh_auction_reading(
          Map.merge(
            %{
              read_block: snapshot.block.number,
              block_hash: snapshot.block.hash,
              read_at: DateTime.utc_now(),
              degraded: unread?,
              market: snapshot.market
            },
            if((displaced? and not unread?) or page_changed?,
              do: %{page: snapshot.page},
              else: %{}
            )
          ),
          actor: @actor
        )
        |> written()
      else
        :ok
      end
    end
  end

  defp written({:ok, _reading}), do: :ok
  defp written({:error, error}), do: {:error, error}

  defp old?(held), do: DateTime.diff(DateTime.utc_now(), held.read_at) >= @fresh_s

  defp market_changed?(held, market), do: Map.take(held, Map.keys(market)) != market

  # Whether a page figure changed, leaving out the block it was read at.
  defp page_changed?(_held, page) when page in [nil, :unread], do: {:ok, false}
  defp page_changed?(nil, _page), do: {:ok, true}

  defp page_changed?(held, page) do
    with {:ok, page} <- Ash.Type.cast_input(Page, page, []),
         {:ok, now} <- figures(page),
         {:ok, before} <- figures(held),
         do: {:ok, now != before}
  end

  defp figures(page) do
    with {:ok, dumped} <- Ash.Type.dump_to_embedded(Page, page, []),
         do: {:ok, Map.drop(dumped, @read_at)}
  end

  # Marks the reading as not read this pass, so its pages show it as it was.
  defp degrade(auction_id) do
    case Autolaunch.get_auction_reading(auction_id, actor: @actor) do
      {:ok, %AuctionReading{degraded: false} = reading} ->
        reading |> Autolaunch.degrade_auction_reading(actor: @actor) |> written()

      {:ok, _none_or_degraded} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end
end
