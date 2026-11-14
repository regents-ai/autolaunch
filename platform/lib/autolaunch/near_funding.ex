defmodule Autolaunch.NearFunding do
  @moduledoc """
  One funding of a bid from NEAR: an exact amount of USDC (`usdc_amount`, base
  units) on Base, bought with the NEAR the person sends to `deposit_address`
  from their own NEAR wallet, delivered to `recipient`, the acting account's
  own signed-in wallet, and refunded to `refund_to`, their NEAR account, if the
  swap does not happen by `deadline`.

  Starting a funding asks the NEAR Intents 1Click service for a quote with a
  deposit address and queues its status job in the same write
  (`Autolaunch.NearFunding.Watch`), which reads the service until the swap
  ends. Each read that changes `state` is broadcast on `Autolaunch.PubSub`,
  topic `"near_funding:<id>"`, as `{:near_funding, record}`. A person or their
  paired agent reads only their own account's fundings.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.Funding,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.NearFunding.Intents

  # A NEAR account name: 2 to 64 lowercase letters, digits and single `-`, `_`
  # or `.` between them (NEAR's own rule), which also covers an implicit
  # account's 64 hex characters.
  @near_account ~r/^(?=.{2,64}$)(([a-z\d]+[\-_])*[a-z\d]+\.)*([a-z\d]+[\-_])*[a-z\d]+$/

  postgres do
    table "near_fundings"
    repo Autolaunch.Repo

    custom_indexes do
      index [:human_account_id, :auction_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    # What the USDC would cost in NEAR now, delivered to the account's wallet.
    # Stores nothing.
    action :quote, :map do
      argument :auction_id, :uuid, allow_nil?: false
      argument :usdc_amount, :integer, allow_nil?: false, constraints: [min: 1]

      run fn %{arguments: arguments}, context ->
        case Intents.quote(
               context.actor,
               arguments.auction_id,
               arguments.usdc_amount,
               nil,
               true
             ) do
          {:ok, terms} -> {:ok, Map.drop(terms, [:deposit_address, :deadline])}
          {:error, reason} -> {:error, Ash.Error.Unknown.UnknownError.exception(error: reason)}
        end
      end
    end

    # Asks the service for a deposit address and records it with its status job.
    create :start do
      argument :auction_id, :uuid, allow_nil?: false
      argument :usdc_amount, :integer, allow_nil?: false, constraints: [min: 1]

      argument :refund_to, :string,
        allow_nil?: false,
        constraints: [match: @near_account, trim?: true]

      change Autolaunch.NearFunding.Start
    end

    # The account's fundings for one auction, newest first.
    read :for_auction do
      argument :auction_id, :uuid, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id))
      prepare build(sort: [inserted_at: :desc])
    end

    # Reads the swap's status from the service once and stores it, so no
    # database transaction is held open around the call.
    update :refresh do
      transaction? false
      require_atomic? false
      change Autolaunch.NearFunding.Refresh
    end
  end

  policies do
    policy action([:quote, :start]) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update]) do
      authorize_if Autolaunch.Checks.SystemActor
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :human_account_id, :integer, allow_nil?: false
    attribute :auction_id, :uuid, allow_nil?: false
    # The acting account's signed-in wallet on Base, lowercase.
    attribute :recipient, :string, allow_nil?: false
    attribute :refund_to, :string, allow_nil?: false
    attribute :usdc_amount, :integer, allow_nil?: false
    # The NEAR to send, rounded up to three decimals, and exactly as quoted
    # (yoctoNEAR).
    attribute :near_amount, :string, allow_nil?: false
    attribute :near_amount_raw, :string, allow_nil?: false
    attribute :deposit_address, :string, allow_nil?: false
    attribute :deadline, :utc_datetime, allow_nil?: false
    attribute :time_estimate_s, :integer, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending_deposit,
      constraints: [one_of: [:pending_deposit, :processing, :success, :refunded, :failed]]

    attribute :origin_tx, :string
    attribute :destination_tx, :string

    timestamps()
  end
end
