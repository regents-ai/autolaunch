defmodule Autolaunch.Stocks.Stock do
  @moduledoc """
  A stock token a launchpad has admitted as a launch currency, one row per
  chain and token address. This table is the site's one list of stocks: the
  picker, search, prices and every action's stock facts read it
  (`Autolaunch.Stocks.Assets`).

  Every five minutes, and once when a server starts, `:sync_admissions` asks
  each stock launchpad about every saved stock and about every stock its
  `StockAdmitted` logs name since the last run, and writes what the chain says
  of each at the latest block (`Autolaunch.Stocks.Stock.SyncAdmissions`):
  whether it is admitted, its decimals and route, the route's price feed, and
  the token's own name and ticker. A stock a launchpad admits therefore shows
  here without a release. A row is not proof of admission at the moment of an
  action: the launchpad's `stockAdmission` is read again before every launch
  and bid.

  A stock's search words start from a set kept here and are ours to change
  after that with `:set_search_words`. A revoked stock keeps its row, so
  auctions already trading in it stay findable by its name.

  Every half hour, each stock on a chain GeckoTerminal reports on whose
  volume has not been counted through yesterday is read again
  (`Autolaunch.Stocks.Stock.ReadWeeklyVolume`), one stock at a time.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Other names people search for, by plain ticker.
  @starting_words %{
    "AAPL" => ["Apple Inc", "iPhone"],
    "AMD" => ["Advanced Micro Devices"],
    "AMZN" => ["Amazon.com", "AWS"],
    "BABA" => ["Alibaba"],
    "COIN" => ["Coinbase"],
    "CRCL" => ["Circle", "USDC"],
    "DELL" => ["Dell Technologies"],
    "GME" => ["GameStop"],
    "GOOGL" => ["Alphabet", "Google"],
    "INTC" => ["Intel"],
    "META" => ["Meta Platforms", "Facebook", "Instagram"],
    "MSFT" => ["Microsoft"],
    "MSTR" => ["Strategy", "MicroStrategy"],
    "MU" => ["Micron Technology"],
    "NVDA" => ["NVIDIA"],
    "PLTR" => ["Palantir"],
    "QQQ" => ["Nasdaq 100", "Invesco QQQ"],
    "SGOV" => ["Treasury bills", "T-bills"],
    "SLV" => ["Silver", "iShares Silver Trust"],
    "SNDK" => ["Sandisk"],
    "SPCX" => ["SpaceX"],
    "SPY" => ["S&P 500", "SPDR"],
    "TSLA" => ["Tesla"],
    "TSM" => ["TSMC", "Taiwan Semiconductor"],
    "USAR" => ["USA Rare Earth"],
    "USO" => ["Oil", "United States Oil Fund"]
  }

  oban do
    scheduled_actions do
      schedule :sync_admissions, "*/5 * * * *" do
        action :sync_admissions
        queue :stock_admissions
        # A failed chain read is tried again in seconds, not at the next run.
        max_attempts 3
        # One run at a time across every server, whether the schedule or a
        # starting server asked for it: a second is not queued while one
        # waits, runs or waits to be tried again.
        worker_opts unique: [fields: [:worker], period: :infinity, states: :incomplete]
        worker_module_name Autolaunch.Stocks.Stock.Workers.SyncAdmissions
      end
    end

    triggers do
      trigger :read_weekly_volume do
        action :read_weekly_volume
        read_action :read
        worker_read_action :read
        queue :stock_volume
        # The scheduler only picks the stocks to read; on the default queue it
        # never waits behind a read that takes minutes.
        scheduler_queue :default
        scheduler_cron "*/30 * * * *"
        max_attempts 1
        # Twice the longest read seen (7.7 minutes), and under the twenty
        # minutes after which a running job counts as orphaned (config.exs).
        timeout :timer.minutes(15)

        where expr(
                chain_id in ^Autolaunch.Stocks.GeckoTerminal.chain_ids() and
                  (is_nil(weekly_volume_through) or
                     weekly_volume_through < fragment("(now() AT TIME ZONE 'UTC')::date - 1"))
              )

        worker_module_name Autolaunch.Stocks.Stock.Workers.ReadWeeklyVolume
        scheduler_module_name Autolaunch.Stocks.Stock.Schedulers.ReadWeeklyVolume
      end
    end
  end

  postgres do
    table "stocks"
    repo Autolaunch.Repo
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    # Every saved row of one chain, for the sync to ask the chain about again.
    read :on_chain do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id))
    end

    # The stocks one chain's launchpad admits or once admitted, with every
    # name each goes by: what `Autolaunch.Stocks.Assets` answers from.
    read :launch_currencies do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and not is_nil(route))
      prepare build(load: [:search_text], sort: [symbol: :asc])
    end

    # What the chain said of one stock at the latest block. Written again on
    # every sync; the search words and offered time set when the row was first
    # written are left alone.
    create :record_admission do
      accept [:chain_id, :address, :symbol, :name, :decimals, :route, :feed, :admitted]
      upsert? true
      upsert_identity :chain_address
      upsert_fields [:symbol, :name, :decimals, :route, :feed, :admitted]
      change set_attribute(:offered_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        ticker =
          changeset
          |> Ash.Changeset.get_attribute(:symbol)
          |> Autolaunch.Stocks.PriceFeeds.ticker()

        Ash.Changeset.force_change_attribute(changeset, :search_words, starting_words(ticker))
      end
    end

    update :set_search_words do
      accept [:search_words]
    end

    # A saved stock the chain's launchpad has never admitted.
    update :withdraw_admission do
      change set_attribute(:admitted, false)
    end

    action :sync_admissions do
      run fn _input, _context -> Autolaunch.Stocks.Stock.SyncAdmissions.run() end
    end

    # Reads GeckoTerminal, then writes the answer, so no database transaction
    # is held open around the reads.
    update :read_weekly_volume do
      require_atomic? false
      transaction? false
      change Autolaunch.Stocks.Stock.ReadWeeklyVolume
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([
             :record_admission,
             :withdraw_admission,
             :set_search_words,
             :read_weekly_volume,
             :sync_admissions
           ]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_id, :integer, allow_nil?: false, public?: true

    attribute :address, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :symbol, :string, allow_nil?: false, public?: true, constraints: [max_length: 32]
    attribute :name, :string, allow_nil?: false, public?: true, constraints: [max_length: 120]

    # What the launchpad and the route said at the last sync. A row written
    # before the site read admissions has none of these until its first sync.
    # A route that names no feed gives the stock no dollar price.
    attribute :admitted, :boolean, allow_nil?: false, default: false, public?: true
    attribute :decimals, :integer, public?: true, constraints: [min: 0, max: 36]
    attribute :route, :string, public?: true, constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]
    attribute :feed, :string, public?: true, constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :search_words, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [items: [max_length: 80]]

    # The USD traded in the stock's dollar-token pools over the seven UTC days
    # ending on `weekly_volume_through`; a floor when not complete, because
    # GeckoTerminal listed the stock's pools over more than one page.
    attribute :weekly_volume_usd, :decimal, public?: true, constraints: [min: 0]
    attribute :weekly_volume_complete, :boolean, allow_nil?: false, default: false, public?: true
    attribute :weekly_volume_through, :date, public?: true

    # When this site first listed the stock: when its row was first written.
    # Stocks it listed before it kept this record have none.
    attribute :offered_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  calculations do
    # Every name the stock goes by, for search.
    calculate :search_text,
              :string,
              expr(
                fragment(
                  "concat_ws(' ', ?, ?, array_to_string(?, ' '))",
                  symbol,
                  name,
                  search_words
                )
              )
  end

  identities do
    identity :chain_address, [:chain_id, :address]
  end

  defp starting_words(ticker), do: Map.get(@starting_words, ticker, [])
end
