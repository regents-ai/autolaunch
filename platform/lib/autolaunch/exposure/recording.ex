defmodule Autolaunch.Exposure.Recording do
  @moduledoc """
  One series the site offers, kept moving: every price is recorded from the
  feed and applied as soon as it may be, and a series whose price can no
  longer be recorded is ended, so no series waits for a visitor to press.

  Every five minutes `:follow` adds a row for each series the site lists, and
  the `:record` trigger looks at each one still running and sends at most one
  transaction for it from the recorder's own wallet (`Autolaunch.Exposure.Record`).
  It runs only on a site switched on with `AUTOLAUNCH_EXPOSURE_RECORDER_ON=true`
  (`config/runtime.exs`); otherwise its queue stays paused and prices are
  recorded from the page.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.Exposure,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    triggers do
      trigger :record do
        action :record
        read_action :read
        worker_read_action :read
        queue :exposure_recording
        scheduler_cron "*/5 * * * *"
        max_attempts 1

        where expr(state == :running)

        worker_module_name Autolaunch.Exposure.Recording.Workers.Record
        scheduler_module_name Autolaunch.Exposure.Recording.Schedulers.Record
      end
    end

    scheduled_actions do
      schedule :follow, "*/5 * * * *" do
        action :follow
        queue :exposure_recording
        worker_module_name Autolaunch.Exposure.Recording.Workers.Follow
      end
    end
  end

  postgres do
    table "exposure_recordings"
    repo Autolaunch.Repo

    identity_index_names one_per_series: "exposure_recordings_series_index"
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    create :add do
      accept [:chain_id, :series]
      upsert? true
      upsert_identity :one_per_series
      upsert_fields []
    end

    action :follow do
      run fn _input, _context -> Autolaunch.Exposure.Record.follow() end
    end

    # Reads the chain and may send a transaction, so no database transaction
    # is held open around it.
    update :record do
      require_atomic? false
      transaction? false
      change Autolaunch.Exposure.Record
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

    attribute :series, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :state, :atom,
      allow_nil?: false,
      default: :running,
      constraints: [one_of: [:running, :ended]]

    timestamps()
  end

  identities do
    identity :one_per_series, [:chain_id, :series]
  end
end
