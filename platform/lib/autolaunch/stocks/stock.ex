defmodule Autolaunch.Stocks.Stock do
  @moduledoc """
  A stock token the site supports as a launch currency, one row per chain and
  token address, so search can find an auction by the stock it trades in.

  `Autolaunch.Stocks.SupportedStocks` records every stock the chains' lists
  offer when the site starts. Its ticker and company name follow those lists;
  its search words start from a set kept here and are ours to change after
  that with `:set_search_words`. A stock that leaves the lists keeps its row,
  so auctions already trading in it stay findable by its name.

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
    triggers do
      trigger :read_weekly_volume do
        action :read_weekly_volume
        read_action :read
        worker_read_action :read
        queue :stock_volume
        scheduler_cron "*/30 * * * *"
        max_attempts 1

        where expr(
                chain_id in ^Autolaunch.Stocks.Stock.ReadWeeklyVolume.chain_ids() and
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

    # One chain's rows, for the stock gallery: when each was first offered
    # here and every name it goes by.
    read :on_chain do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id))
      prepare build(load: [:search_text])
    end

    # Recorded again on every start; the search words and offered time set
    # when the row was first written are left alone.
    create :record_supported do
      accept [:chain_id, :address, :symbol, :name]
      upsert? true
      upsert_identity :chain_address
      upsert_fields [:symbol, :name]
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

    policy action([:record_supported, :set_search_words, :read_weekly_volume]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_id, :integer, allow_nil?: false, public?: true

    attribute :address, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-fA-F]{40}\z/]

    attribute :symbol, :string, allow_nil?: false, public?: true, constraints: [max_length: 32]
    attribute :name, :string, allow_nil?: false, public?: true, constraints: [max_length: 120]

    attribute :search_words, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [items: [max_length: 80]]

    # The USD traded in the stock's dollar-token pools over the seven UTC days
    # ending on `weekly_volume_through`.
    attribute :weekly_volume_usd, :decimal, public?: true, constraints: [min: 0]
    attribute :weekly_volume_through, :date, public?: true

    # When this site first listed the stock: the start that wrote its row.
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
