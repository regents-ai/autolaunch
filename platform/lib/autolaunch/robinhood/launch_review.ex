defmodule Autolaunch.Robinhood.LaunchReview do
  @moduledoc """
  A Robinhood launch this site prepared for one of its accounts, stored when the
  review is built so the launch is known as the site's even if the creator's
  browser never reports it back.

  Robinhood discovery (`Autolaunch.Robinhood.Discovery`) matches each launch it
  finds to these reviews:
  one whose wallet launched it with exactly the reviewed name, symbol and
  stock makes it a site launch, in that review's
  account, with the Telegram, Discord and other links the review carried; no
  match makes it a launch seen only on chain. The review a launch is listed
  from is marked `adopted_at` in the same write as the listing; the mark does
  not change what `:matching` finds.

  A paired agent's review of the person's draft (`prepared_by: :agent`,
  `Autolaunch.AgentLaunch`) is matched only when none of the person's is, so it
  never takes the place of one the person saw. Preparing again for a changed
  draft keeps the latest 20 preparations of the person on that chain
  (`Autolaunch.AgentLaunch.Preparations`).
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Sort

  postgres do
    table "robinhood_launch_reviews"
    repo Autolaunch.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :chain_id,
        :signer,
        :human_account_id,
        :name,
        :symbol,
        :stock,
        :telegram,
        :discord,
        :links
      ]
    end

    # A paired agent's review of its person's draft (`Autolaunch.AgentLaunch`),
    # kept for the person the pairing names while the pairing is locked.
    create :agent_record do
      accept [:chain_id, :signer, :name, :symbol, :stock, :telegram, :discord, :links]
      change set_attribute(:human_account_id, actor(:human_account_id))
      change set_attribute(:prepared_by, :agent)
      change {RegentAgents.RequirePairing, repo: Autolaunch.Repo}

      change {Autolaunch.AgentLaunch.Preparations,
              of: [:human_account_id, :chain_id],
              same: [:signer, :name, :symbol, :stock, :telegram, :discord, :links]}
    end

    # An agent's reviews no launch was listed from, newest first
    # (`Autolaunch.AgentLaunch.Preparations`).
    read :agent_preparations do
      filter expr(prepared_by == :agent and is_nil(adopted_at))
      prepare build(sort: [inserted_at: :desc])
    end

    # An agent's review that its latest ones replaced.
    destroy :trim do
      validate attribute_equals(:prepared_by, :agent)
      validate absent(:adopted_at)
    end

    # Discovery lists a launch from this review (`Autolaunch.Robinhood.Discovery`).
    update :adopt do
      accept []
      change set_attribute(:adopted_at, &DateTime.utc_now/0)
    end

    # The review that carried out this exact launch: the person's newest, or
    # with none of theirs, the newest an agent prepared.
    read :matching do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :signer, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :symbol, :string, allow_nil?: false
      argument :stock, :string, allow_nil?: false

      filter expr(
               chain_id == ^arg(:chain_id) and signer == ^arg(:signer) and name == ^arg(:name) and
                 symbol == ^arg(:symbol) and stock == ^arg(:stock)
             )

      prepare build(
                sort: [
                  {Ash.Sort.expr_sort(prepared_by == :agent, :boolean), :asc},
                  inserted_at: :desc
                ],
                limit: 1
              )
    end
  end

  policies do
    bypass action(:agent_record) do
      authorize_if {RegentAgents.Checks.Paired, repo: Autolaunch.Repo}
    end

    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]

    # Addresses are stored lowercase.
    attribute :signer, :string, allow_nil?: false, constraints: [min_length: 42, max_length: 42]
    attribute :human_account_id, :integer, allow_nil?: false
    attribute :name, :string, allow_nil?: false, constraints: [trim?: false]
    attribute :symbol, :string, allow_nil?: false, constraints: [trim?: false]
    attribute :stock, :string, allow_nil?: false, constraints: [min_length: 42, max_length: 42]
    attribute :telegram, :string, constraints: [max_length: 256]
    attribute :discord, :string, constraints: [max_length: 256]

    attribute :links, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [max_length: 3, items: [max_length: 256]]

    # Set only by `:agent_record`.
    attribute :prepared_by, :atom,
      allow_nil?: false,
      default: :person,
      constraints: [one_of: [:person, :agent]]

    # Set only by `:adopt`; nil until a launch is listed from this review.
    attribute :adopted_at, :utc_datetime_usec

    create_timestamp :inserted_at
  end
end
