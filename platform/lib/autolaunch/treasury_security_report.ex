defmodule Autolaunch.TreasurySecurityReport do
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @classifications [
    :supported_safe,
    :safe_1_of_1,
    :eoa,
    :delegated_eoa,
    :unknown_contract,
    :split,
    :unsupported
  ]

  @verification_states [:verified, :unverified]
  @downgrade_states [:none, :downgraded]

  @derived_fields [
    :address,
    :chain_id,
    :classification,
    :safe_version,
    :safe_singleton,
    :owner_addresses,
    :owner_count,
    :threshold,
    :modules,
    :guard,
    :fallback_handler,
    :configuration_fingerprint,
    :source_block_number,
    :source_block_hash,
    :observed_at,
    :verification_state,
    :verification_reason,
    :usdc_evidence,
    :regent_evidence,
    :outbound_evidence,
    :downgrade_state,
    :prior_verified_fingerprint
  ]

  postgres do
    table "treasury_security_reports"
    repo Autolaunch.Repo

    custom_indexes do
      index [:address, :source_block_number]
    end
  end

  actions do
    read :read do
      primary? true
    end

    read :for_address do
      argument :address, :string, allow_nil?: false
      filter expr(address == ^arg(:address))
      prepare build(sort: [source_block_number: :desc, inserted_at: :desc, id: :desc])
    end

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :record_observation do
      accept @derived_fields
    end
  end

  policies do
    policy action([:read, :for_address, :by_id]) do
      authorize_if always()
    end

    policy action(:record_observation) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :address, :string do
      allow_nil? false
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-f]{40}\z/
    end

    attribute :chain_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :classification, :atom do
      allow_nil? false
      public? true
      constraints one_of: @classifications
    end

    attribute :safe_version, :string, public?: true
    attribute :safe_singleton, :string, public?: true

    attribute :owner_addresses, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :owner_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :threshold, :integer do
      public? true
      constraints min: 0
    end

    attribute :modules, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :guard, :string, public?: true
    attribute :fallback_handler, :string, public?: true

    attribute :configuration_fingerprint, :string do
      allow_nil? false
      public? true
      constraints min_length: 66, max_length: 66, match: ~r/\A0x[0-9a-f]{64}\z/
    end

    attribute :source_block_number, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :source_block_hash, :string do
      allow_nil? false
      public? true
      constraints min_length: 66, max_length: 66, match: ~r/\A0x[0-9a-f]{64}\z/
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :verification_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: @verification_states
    end

    attribute :verification_reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :usdc_evidence, :map, public?: true
    attribute :regent_evidence, :map, public?: true
    attribute :outbound_evidence, :map, public?: true

    attribute :downgrade_state, :atom do
      allow_nil? false
      public? true
      default :none
      constraints one_of: @downgrade_states
    end

    attribute :prior_verified_fingerprint, :string do
      public? true
      constraints min_length: 66, max_length: 66, match: ~r/\A0x[0-9a-f]{64}\z/
    end

    timestamps()
  end
end
