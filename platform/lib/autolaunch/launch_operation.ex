defmodule Autolaunch.LaunchOperation do
  @moduledoc """
  One launch review this site built for an account, saved so the launch it
  carries out is known as this site's whether or not the page is still open.

  `review` is fixed once saved: the chain, the signer, the one `launch` step
  (target and calldata) and the facts the page showed. Nothing about a press is
  stored. `Autolaunch.LaunchReviews` matches a launch the chain shows to the
  review whose step it sent, lists it, and marks the review `chain_verified`.

  A review stays `prepared` until the chain shows its launch, even once its
  page has let it go: its exact step can still be sent, and the launch is then
  this site's. An account may hold any number of reviews; one never cancels
  another.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:launch]
  @states [:prepared, :chain_verified]

  postgres do
    table "launch_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :launch_draft, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    # `Autolaunch.LaunchReviews`: the review a page's own press names,
    read :by_action_id do
      get? true
      argument :action_id, :string, allow_nil?: false
      filter expr(action_id == ^arg(:action_id))
    end

    # the reviews a launch the chain shows may have come from, newest first,
    read :for_signer_on_chain do
      argument :signer, :string, allow_nil?: false
      argument :chain_id, :integer, allow_nil?: false

      filter expr(
               string_downcase(signer) == string_downcase(^arg(:signer)) and
                 fragment("(?->'chain'->>'chain_id')::bigint = ?", review, ^arg(:chain_id))
             )

      prepare build(sort: [inserted_at: :desc])
    end

    # and the one being listed, held until its listing commits.
    read :by_id_for_update do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    # The chain shows the launch this review's step carried out.
    update :verify do
      accept [:result]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :chain_verified)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    create :prepare do
      accept [:action_id, :review, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      argument :launch_draft_id, :uuid, allow_nil?: false
      change set_attribute(:human_account_id, arg(:human_account_id))
      change set_attribute(:launch_draft_id, arg(:launch_draft_id))
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    # Never accepted by an update: the reviewed identity is the operation.
    attribute :action_id, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :review, :map, source: :envelope, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

    # Adopted from the verified `LaunchCreated`, never guessed before mining: the
    # launch id, subject, auction, escrow and the fixed schedule it recorded.
    attribute :result, :map, default: %{}

    # Written by nothing; dropped by the next release, once no machine of the
    # release before this one still reads it.
    attribute :reason, :string, constraints: [max_length: 120]
    attribute :terminal_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end

    belongs_to :launch_draft, Autolaunch.LaunchDraft do
      allow_nil? false
    end
  end

  identities do
    identity :unique_launch_action_id, [:action_id]
  end
end
