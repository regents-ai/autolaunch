defmodule Autolaunch.LaunchJob do
  alias Autolaunch.LaunchIdentity

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "launch_jobs"
    repo Autolaunch.Repo
  end

  actions do
    read :read do
      primary? true
    end

    read :list_public do
      prepare build(sort: [inserted_at: :desc, id: :asc], load: [:treasury_security_report])
    end

    read :public_by_id do
      get? true

      argument :job_id, :string,
        allow_nil?: false,
        constraints: LaunchIdentity.constraints()

      filter expr(job_id == ^arg(:job_id))
      prepare build(load: [:treasury_security_report])
    end

    create :project_lab do
      accept [
        :job_id,
        :status,
        :step,
        :agent_id,
        :agent_name,
        :token_name,
        :token_symbol,
        :chain_id,
        :auction_id,
        :agent_safe_address,
        :auction_address,
        :token_address,
        :hook_address,
        :revenue_share_splitter_address,
        :treasury_address,
        :started_at,
        :finished_at
      ]

      upsert? true
      upsert_identity :unique_job_id

      upsert_fields [
        :status,
        :step,
        :auction_id,
        :agent_safe_address,
        :auction_address,
        :token_address,
        :hook_address,
        :revenue_share_splitter_address,
        :treasury_address,
        :started_at,
        :finished_at
      ]
    end
  end

  policies do
    policy action([:read, :list_public, :public_by_id]) do
      authorize_if always()
    end

    policy action(:project_lab) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id, public?: false

    attribute :job_id, :string do
      allow_nil? false
      public? true
      constraints LaunchIdentity.constraints()
    end

    attribute :status, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :step, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128, trim?: true
    end

    attribute :agent_name, :string do
      public? true
      constraints max_length: 160, trim?: true
    end

    attribute :token_name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :token_symbol, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 16, match: ~r/\A[A-Z0-9]+\z/
    end

    attribute :chain_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :agent_safe_address, :string do
      public? true
      constraints max_length: 128, trim?: true
    end

    attribute :auction_address, :string do
      public? true
      constraints max_length: 128, trim?: true
    end

    attribute :token_address, :string do
      public? true
      constraints max_length: 128, trim?: true
    end

    attribute :hook_address, :string do
      public? true
      constraints max_length: 128, trim?: true
    end

    attribute :revenue_share_splitter_address, :string do
      public? true
      constraints max_length: 128, trim?: true
    end

    attribute :treasury_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      attribute_public? true
    end

    belongs_to :treasury_security_report,
               Autolaunch.TreasurySecurityReport do
      attribute_public? true
    end
  end

  identities do
    identity :unique_job_id, [:job_id]
  end
end
