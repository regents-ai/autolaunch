defmodule Autolaunch.ShareVideoRequest do
  @moduledoc """
  One share video asked for (`AutolaunchWeb.ShareVideo`) and, once made, the
  video itself: what it is of (a launch's token or running auction, by
  `auction_id`; a covered-call market or an After-hours Exposure series, by
  `subject`, its symbol or address), and for a person's own video the
  signed-in account and its wallet.
  A launch's own video is named by `key`, which moves on every fifteen minutes;
  a person's are theirs for that launch or market, kind and wallet.

  Writing a request queues its `:render` job in the same write. The
  `share_videos` queue renders one at a time, so how many requests are still
  queued before a row is its place in line. A render that succeeds stores the
  video in the row and marks it ready; one that fails marks it failed.

  A video is queued once: a request for a video already queued is that queued
  row, however many ask at once (the `:queued_key` identity). The site makes
  at most 1000 videos in any 24 hours: every request in that time apart from
  failed ones, counted inside a person's request's own write
  (`Autolaunch.ShareVideoRequest.Changes.DailyLimit`); a launch's own videos
  are always made. A saved video is deleted once it is a day old, within the
  hour; the request it came from stays. Saved videos hold at most about 5 GB: past
  that, a video is still made but not saved (`saved` false), and once handed
  over its bytes are let go (`:hand_over`). No video is ever deleted early.
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

      # A saved video goes once it is a day old; its request stays.
      trigger :forget do
        action :forget_video
        where expr(not is_nil(mp4) and inserted_at < ago(1, :day))
        queue :default
        scheduler_cron "41 * * * *"
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
      index [:human_account_id, :auction_id, :kind, :inserted_at]
      index [:human_account_id, :subject, :kind, :inserted_at]
    end

    identity_wheres_to_sql queued_key: "state = 'queued'"
  end

  actions do
    defaults [:read, :destroy]

    # A video already queued answers with its queued row and changes nothing.
    create :request do
      accept [:key, :kind, :auction_id, :subject, :human_account_id, :wallet]
      upsert? true
      upsert_identity :queued_key
      upsert_fields []
      validate present(:auction_id), where: [attribute_in(:kind, [:token, :auction])]
      validate present(:subject), where: [attribute_in(:kind, [:covered_calls, :exposure])]
      change set_attribute(:state, :queued)
      change Autolaunch.ShareVideoRequest.Changes.DailyLimit
      change run_oban_trigger(:render)
    end

    # The newest request for a video.
    read :latest do
      get? true
      argument :key, :string, allow_nil?: false
      filter expr(key == ^arg(:key))
      prepare build(sort: [inserted_at: :desc], limit: 1, load: [:stored?])
    end

    # Requests still waiting for the queue, oldest first.
    read :queued do
      filter expr(state == :queued)
      prepare build(sort: [inserted_at: :asc])
    end

    # A person's requests for one launch, kind and wallet in the last day, newest
    # first.
    read :own do
      argument :human_account_id, :integer, allow_nil?: false
      argument :auction_id, :uuid, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:token, :auction]]
      argument :wallet, :string, allow_nil?: false

      filter expr(
               human_account_id == ^arg(:human_account_id) and auction_id == ^arg(:auction_id) and
                 kind == ^arg(:kind) and wallet == ^arg(:wallet) and inserted_at > ago(1, :day)
             )

      prepare build(sort: [inserted_at: :desc], limit: 5, load: [:stored?])
    end

    # A person's requests for one market or series, kind and wallet in the
    # last day, newest first.
    read :own_market do
      argument :human_account_id, :integer, allow_nil?: false
      argument :subject, :string, allow_nil?: false
      argument :wallet, :string, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:covered_calls, :exposure]]

      filter expr(
               human_account_id == ^arg(:human_account_id) and subject == ^arg(:subject) and
                 kind == ^arg(:kind) and wallet == ^arg(:wallet) and inserted_at > ago(1, :day)
             )

      prepare build(sort: [inserted_at: :desc], limit: 5, load: [:stored?])
    end

    # Every video the site has made or is making in the last 24 hours.
    read :made_today do
      filter expr(state != :failed and inserted_at > ago(24, :hour))
    end

    # Whether the made videos still held come to less than `bytes`.
    action :room, :boolean do
      argument :bytes, :integer, allow_nil?: false
      run Autolaunch.ShareVideoRequest.Actions.Room
    end

    # One made video, with its bytes.
    read :video do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare build(select: [:id, :mp4, :saved])
    end

    # A video made but not saved, handed over: its bytes are let go.
    update :hand_over do
      change set_attribute(:mp4, nil)
    end

    # A saved video a day old: its bytes are let go and its request stays.
    update :forget_video do
      change set_attribute(:mp4, nil)
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

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:token, :auction, :covered_calls, :exposure]]

    # The launch, for a token's or an auction's video.
    attribute :auction_id, :uuid
    # The market's symbol or the series' address, for a covered-call or an
    # After-hours Exposure video.
    attribute :subject, :string
    # The signed-in account a person's own video is for; nil for a launch's own.
    attribute :human_account_id, :integer
    attribute :wallet, :string

    # The finished MP4, read only by `:video`.
    attribute :mp4, :binary, select_by_default?: false
    # False for a video made once saved videos were full: it is handed over once.
    attribute :saved, :boolean, allow_nil?: false, default: true

    attribute :state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:queued, :ready, :failed]]

    timestamps()
  end

  calculations do
    # Whether the row holds its finished video.
    calculate :stored?, :boolean, expr(not is_nil(mp4))
    # The finished MP4's size in bytes, read without reading the video.
    calculate :size, :integer, expr(fragment("octet_length(?)", mp4))
  end

  identities do
    identity :queued_key, [:key], where: expr(state == :queued)
  end
end
