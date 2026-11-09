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

    create :project_lab do
      accept [
        :job_id,
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
        :treasury_address
      ]

      upsert? true
      upsert_identity :unique_job_id

      upsert_fields [
        :auction_id,
        :agent_safe_address,
        :auction_address,
        :token_address,
        :hook_address,
        :revenue_share_splitter_address,
        :treasury_address
      ]
    end
  end

  policies do
    policy action(:read) do
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

    # Never advanced past what launch discovery first wrote, and read by
    # nothing; these four columns are dropped by the next release, once no
    # machine of the release before still reads them.
    attribute :status, :string do
      allow_nil? false
      select_by_default? false
      default "active"
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :step, :string do
      allow_nil? false
      select_by_default? false
      default "auction"
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
      select_by_default? false
    end

    attribute :finished_at, :utc_datetime_usec do
      select_by_default? false
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
