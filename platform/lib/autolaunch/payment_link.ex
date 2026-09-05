defmodule Autolaunch.PaymentLink do
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "payment_links"
    repo Autolaunch.Repo

    custom_indexes do
      index [:subject_id]
    end
  end

  actions do
    read :by_subject_and_receiver do
      public? false
      get? true

      argument :subject_id, :uuid, allow_nil?: false

      argument :receiver_address, :string,
        allow_nil?: false,
        constraints: [min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-f]{40}\z/]

      filter expr(
               subject_id == ^arg(:subject_id) and
                 receiver_address == ^arg(:receiver_address)
             )
    end

    create :record_confirmation do
      public? false
      accept []

      argument :subject_id, :uuid, allow_nil?: false

      argument :receiver_address, :string,
        allow_nil?: false,
        constraints: [min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-f]{40}\z/]

      argument :label, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 96, trim?: true]

      change set_attribute(:subject_id, arg(:subject_id))
      change set_attribute(:receiver_address, arg(:receiver_address))
      change set_attribute(:label, arg(:label))

      upsert? true
      upsert_identity :unique_receiver_address
      upsert_fields []
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id, public?: false

    attribute :receiver_address, :string do
      allow_nil? false
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-f]{40}\z/
    end

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 96, trim?: true
    end

    create_timestamp :created_at
  end

  relationships do
    belongs_to :subject, Autolaunch.Subject do
      allow_nil? false
    end
  end

  identities do
    identity :unique_receiver_address, [:receiver_address]
  end
end
