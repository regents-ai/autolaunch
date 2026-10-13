defmodule Autolaunch.Stocks.StockCandidate do
  @moduledoc """
  A stock Chainlink prices on a launch chain that the chain's stock launchpad
  does not admit: a candidate for the Safe to admit, with what the last look
  found of it. One row per chain and ticker.

  Every hour `:list_feeds` reads Chainlink's public feed list for each chain
  (`Autolaunch.Stocks.StockCandidate.ListFeeds`) and keeps a row for each
  stock feed whose ticker no admitted stock carries; a row whose feed has left
  the list, or whose stock has since been admitted, is removed. Then each row
  is read, one at a time (`Autolaunch.Stocks.StockCandidate.ReadMarket`): the
  feed is asked on the chain whether it answers, GeckoTerminal is asked for
  the stock's dollar pools, and the token is asked on the chain whether it is
  the issuer's. The row then says one of:

  - `:qualifies`: the feed answers and the issuer's token has a dollar pool
    with more than $10,000 in it.
  - `:thin_pool`: its deepest dollar pool holds $10,000 or less.
  - `:no_dollar_pool`: no dollar pool of the issuer's token was found.
  - `:feed_silent`: the feed gives no price, or one more than seven days old.
  - `:unread`: listed and not read yet.

  The rows are advice for the people who sign an admission, and nothing more.
  The feed list and the pool figures come from outside services, and nothing
  here proves a token is the issuer's own: the marks checked can be copied.
  No launch, bid, picker or price reads this table; those read
  `Autolaunch.Stocks.Stock`, which is written only from the launchpads' own
  answers. Nothing here signs or sends a transaction.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    scheduled_actions do
      schedule :list_feeds, "5 * * * *" do
        action :list_feeds
        queue :outside_calls
        max_attempts 3
        # One run at a time across every server.
        worker_opts unique: [fields: [:worker], period: :infinity, states: :incomplete]
        worker_module_name Autolaunch.Stocks.StockCandidate.Workers.ListFeeds
      end
    end

    triggers do
      trigger :read_market do
        action :read_market
        read_action :read
        worker_read_action :read
        # GeckoTerminal's queue, one read at a time: its free service counts
        # these reads and the weekly volume reads together.
        queue :stock_volume
        scheduler_queue :default
        scheduler_cron "20 * * * *"
        # A failed read is tried again at the next hour.
        max_attempts 1
        # One refused GeckoTerminal read waits up to two and a quarter
        # minutes, and at most twenty tokens are asked of the chain at eight
        # seconds a call; under the twenty minutes after which a running job
        # counts as orphaned (config.exs).
        timeout :timer.minutes(10)
        worker_module_name Autolaunch.Stocks.StockCandidate.Workers.ReadMarket
        scheduler_module_name Autolaunch.Stocks.StockCandidate.Schedulers.ReadMarket
      end
    end
  end

  postgres do
    table "stock_candidates"
    repo Autolaunch.Repo
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :on_chain do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id))
      prepare build(sort: [ticker: :asc])
    end

    # A stock feed Chainlink lists; what an earlier read found is kept.
    create :list do
      accept [:chain_id, :ticker, :feed]
      upsert? true
      upsert_identity :chain_ticker
      upsert_fields [:feed]
    end

    destroy :unlist

    action :list_feeds do
      run fn _input, _context -> Autolaunch.Stocks.StockCandidate.ListFeeds.run() end
    end

    # Reads the chain and GeckoTerminal, then writes the answer, so no
    # database transaction is held open around the reads.
    update :read_market do
      require_atomic? false
      transaction? false
      change Autolaunch.Stocks.StockCandidate.ReadMarket
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]

    # The exchange ticker, as Chainlink's list names the feed.
    attribute :ticker, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[A-Z0-9.]{1,12}\z/]

    attribute :feed, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :status, :atom,
      allow_nil?: false,
      default: :unread,
      constraints: [one_of: [:unread, :qualifies, :thin_pool, :no_dollar_pool, :feed_silent]]

    # The issuer's token and its deepest dollar pool at the last read: the
    # pool as GeckoTerminal names it (an address, or a pool id on Uniswap v4),
    # the venue under GeckoTerminal's name for it, and the USD in the pool.
    attribute :token, :string, constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]
    attribute :pool, :string, constraints: [max_length: 120]
    attribute :venue, :string, constraints: [max_length: 80]
    attribute :liquidity_usd, :decimal, constraints: [min: 0]
    attribute :read_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :chain_ticker, [:chain_id, :ticker]
  end
end
