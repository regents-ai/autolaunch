defmodule Autolaunch.ShareVideoRequest do
  @moduledoc """
  One share video asked for (`AutolaunchWeb.ShareVideo`): the launch, whether
  it is the token's video or the running auction's, and for a person's own
  video the signed-in account and its wallet. `key` names the video as it
  stands, so every request for the same video waits on one row.

  Writing a request queues its `:render` job in the same write. The
  `share_videos` queue renders one at a time, so how many requests are still
  queued before a row is its place in line. A render that succeeds keeps the
  video and marks the row ready; one that fails marks it failed.

  A video is queued once: a request for a video already queued is that queued
  row, however many ask at once (the `:queued_key` identity). An account makes
  at most three new videos of its own in any 24 hours: its requests in that
  time, apart from failed ones, one per video, counted inside the request's own
  write (`Autolaunch.ShareVideoRequest.Changes.DailyLimit`). Rows are forgotten
  after a week.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    triggers do
      # Every request queues its own job as it is written, so there is no sweep.
      trigger :render do
        action :render
        where expr(state == :queued)
        queue :share_videos
        max_attempts 1
        on_error :fail
        lock_for_update? false
        scheduler_cron false
        worker_module_name Autolaunch.ShareVideoRequest.Workers.Render
      end

      trigger :forget do
        action :destroy
        where expr(inserted_at < ago(7, :day))
        queue :default
        scheduler_cron "41 4 * * *"
        worker_module_name Autolaunch.ShareVideoRequest.Workers.Forget
        scheduler_module_name Autolaunch.ShareVideoRequest.Schedulers.Forget
      end
    end
  end

  postgres do
    table "share_video_requests"
    repo Autolaunch.Repo

    custom_indexes do
      index [:key, :inserted_at]
      index [:state, :inserted_at]
      index [:human_account_id, :inserted_at]
    end

    identity_wheres_to_sql queued_key: "state = 'queued'"
  end

  actions do
    defaults [:read, :destroy]

    # A video already queued answers with its queued row and changes nothing.
    create :request do
      accept [:key, :kind, :auction_id, :human_account_id, :wallet]
      upsert? true
      upsert_identity :queued_key
      upsert_fields []
      change set_attribute(:state, :queued)
      change Autolaunch.ShareVideoRequest.Changes.DailyLimit
      change run_oban_trigger(:render)
    end

    # The newest request for a video.
    read :latest do
      get? true
      argument :key, :string, allow_nil?: false
      filter expr(key == ^arg(:key))
      prepare build(sort: [inserted_at: :desc], limit: 1)
    end

    # Requests still waiting for the queue, oldest first.
    read :queued do
      filter expr(state == :queued)
      prepare build(sort: [inserted_at: :asc])
    end

    # An account's own videos in the last 24 hours, apart from failed ones.
    read :made_today do
      argument :human_account_id, :integer, allow_nil?: false

      filter expr(
               human_account_id == ^arg(:human_account_id) and state != :failed and
                 inserted_at > ago(24, :hour)
             )
    end

    # Draws and encodes the video, so no database transaction is held open
    # around it.
    update :render do
      transaction? false
      require_atomic? false
      change AutolaunchWeb.ShareVideo.Render
    end

    update :fail do
      change set_attribute(:state, :failed)
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

    attribute :key, :string, allow_nil?: false
    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: [:token, :auction]]
    attribute :auction_id, :uuid, allow_nil?: false
    # The signed-in account a person's own video is for; nil for a launch's own.
    attribute :human_account_id, :integer
    attribute :wallet, :string

    attribute :state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:queued, :ready, :failed]]

    timestamps()
  end

  identities do
    identity :queued_key, [:key], where: expr(state == :queued)
  end
end
