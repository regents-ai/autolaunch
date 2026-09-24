defmodule Autolaunch.Robinhood.LaunchReview do
  @moduledoc """
  A Robinhood launch this site prepared for one of its accounts, stored when the
  review is built so the launch is known as the site's even if the creator's
  browser never reports it back.

  The Robinhood market feed matches each launch it discovers to these reviews:
  one whose wallet launched it with exactly the reviewed name, symbol, stock,
  required raise and floor price makes it a site launch, in that review's
  account; no match makes it a launch seen only on chain.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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
        :required_stock_raised,
        :floor_price_q96
      ]
    end

    # The newest review that carried out this exact launch.
    read :matching do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :signer, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :symbol, :string, allow_nil?: false
      argument :stock, :string, allow_nil?: false
      argument :required_stock_raised, :string, allow_nil?: false
      argument :floor_price_q96, :string, allow_nil?: false

      filter expr(
               chain_id == ^arg(:chain_id) and signer == ^arg(:signer) and name == ^arg(:name) and
                 symbol == ^arg(:symbol) and stock == ^arg(:stock) and
                 required_stock_raised == ^arg(:required_stock_raised) and
                 floor_price_q96 == ^arg(:floor_price_q96)
             )

      prepare build(sort: [inserted_at: :desc], limit: 1)
    end
  end

  policies do
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

    # Exact integers, in the stock's base units and Q96.
    attribute :required_stock_raised, :string, allow_nil?: false
    attribute :floor_price_q96, :string, allow_nil?: false

    create_timestamp :inserted_at
  end
end
