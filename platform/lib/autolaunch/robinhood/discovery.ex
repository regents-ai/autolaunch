defmodule Autolaunch.Robinhood.Discovery do
  @moduledoc """
  Keeps every Robinhood launch in the `auctions` table. Each `launches(id)`
  record the Robinhood launchpad holds becomes an `Auction` row (kind
  `:stocks`, the Robinhood chain id), written once on the chain-and-address
  identity with the launch's token, launch id and schedule (start and end
  blocks in the rollup clock): a row that already exists is never overwritten.
  This is the only writer that creates Robinhood rows; `Autolaunch.AuctionMarket`
  keeps them current from then on.

  A launch made outside the site is a row too, with origin `:chain`; one that
  matches a review this site stored (`Autolaunch.Robinhood.LaunchReview`) has
  origin `:site`, names that review's account as its creator, and starts that
  account's draft over. Only site launches are listed.

  One job (`Autolaunch.ChainWatch` makes sure of it) reads the launch ids that
  have no row yet, at most two hundred a pass, then waits five minutes (a
  second on a lab); a press that lands on the Robinhood chain brings it
  forward to ten seconds away (`refresh/1`). A record that cannot be read is
  one warning line and is read again on the next pass, as is one the auctions
  table refuses (metadata outside its limits), which never fits. Launch ids are
  told apart by number only, so on a lab started over the new run's first
  launches stay unlisted until its ids pass the old run's.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete]

  @behaviour Autolaunch.ChainRefresh

  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.{Auction, ChainRefresh, ChainWatch, LabProjection, LaunchedDrafts}
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.Robinhood.{Lab, Launchpad}
  alias Autolaunch.Stocks.LaunchActions

  @actor %System{}
  @unavailable [:chain_unavailable, :invalid_chain_response, :invalid_block_header, :wrong_chain]
  @page 200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case pass() do
      :ok ->
        {:snooze, if(Lab.test_chain?(), do: 1, else: 300)}

      {:error, reason} when reason in @unavailable ->
        Logger.warning("Robinhood launches not read (#{reason}); reading again in a minute")
        {:snooze, 60}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 60

  @doc "The discovery job, while this site describes a Robinhood deployment (`Autolaunch.ChainWatch`)."
  def jobs, do: if(Lab.configured?(), do: [new(%{})], else: [])

  @doc "A press landed on the Robinhood chain: its new launches are read ten seconds from now."
  # No job runs while the site is read-only before launch (`Autolaunch.Application`).
  @impl ChainRefresh
  def refresh(chain_id) do
    if Lab.chain?(chain_id) and not Autolaunch.Prelaunch.read_only?(),
      do: ChainWatch.soon(new(%{}))

    :ok
  end

  @doc "Lists the launches the launchpad holds that have no row yet."
  def pass do
    with {:ok, head} <- Launchpad.head(),
         {:ok, next} <- Launchpad.next_launch_id(head) do
      known = known(head.chain_id)

      1..(next - 1)//1
      |> Stream.reject(&MapSet.member?(known, &1))
      |> Enum.take(@page)
      |> Enum.each(&discover(head, &1))
    end
  end

  defp known(chain_id) do
    Auction
    |> Ash.Query.for_read(:market, %{}, actor: @actor)
    |> Ash.Query.filter(chain_id == ^chain_id and not is_nil(launch_id))
    |> Ash.Query.select([:launch_id])
    |> Ash.read!()
    |> MapSet.new(& &1.launch_id)
  end

  defp discover(head, launch_id) do
    with {:ok, launch} <- Launchpad.launch(head, launch_id),
         {:ok, origin} <- origin(head.chain_id, launch),
         {:ok, _auction} <- Ash.transaction(Auction, fn -> project(head, launch, origin) end) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Robinhood launch #{launch_id} not listed: #{inspect(reason)}")
    end
  end

  # A launch this site prepared is the site's, in the account the review was
  # for; any other launch was only seen on chain.
  defp origin(chain_id, launch) do
    case Autolaunch.matching_robinhood_launch_review(
           chain_id,
           String.downcase(launch.launcher),
           launch.name,
           launch.symbol,
           String.downcase(launch.stock.address),
           actor: @actor
         ) do
      {:ok, %{human_account_id: account_id} = review} ->
        {:ok, {:site, account_id, Map.take(review, [:telegram, :discord, :links])}}

      {:ok, nil} ->
        {:ok, {:chain, nil, %{}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A site launch's draft starts over with its listing.
  defp project(head, launch, origin) do
    with {:ok, auction} <- record(head, launch, origin),
         :ok <- LabProjection.project_graduated_token(auction),
         :ok <- start_over(origin, launch) do
      auction
    else
      {:error, reason} -> Ash.DataLayer.rollback(Auction, reason)
    end
  end

  defp start_over({:site, account_id, _links}, launch),
    do: LaunchedDrafts.clear(:memestock, account_id, launch.name, launch.symbol)

  defp start_over({:chain, nil, _links}, _launch), do: :ok

  defp record(head, launch, {origin, creator_id, links}) do
    Autolaunch.record_launch_auction(
      Map.merge(links, %{
        kind: :stocks,
        origin: origin,
        chain_id: head.chain_id,
        auction_address: launch.auction,
        creator_human_account_id: creator_id,
        creator_address: String.downcase(launch.launcher),
        title: launch.name,
        summary: launch.description,
        token_symbol: String.slice(launch.symbol, 0, 16),
        website: launch.website,
        image: launch.image,
        featured: false,
        state:
          MarketState.observed(launch.lifecycle, head.clock, launch.start_block, launch.end_block),
        quote_token_address: launch.stock.address,
        quote_token_symbol: launch.stock.symbol,
        quote_token_decimals: launch.stock.decimals,
        current_clearing_price: "0",
        required_currency_raised: Integer.to_string(LaunchActions.required_stock_raised()),
        treasury_address: launch.launchpad,
        token_address: launch.token,
        launch_id: launch.launch_id,
        start_block: launch.start_block,
        end_block: launch.end_block
      }),
      actor: @actor
    )
  end
end
