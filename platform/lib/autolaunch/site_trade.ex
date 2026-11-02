defmodule Autolaunch.SiteTrade do
  @moduledoc """
  A swap sent from this site's trade panel: the transaction the wallet handed
  back, saved with the signed-in account and the wallet that signed it. It is a
  record for Regent Points only, which counts the trade once the site's own
  chain feed (`Autolaunch.TokenTrade`) holds that transaction's swap from that
  wallet (`Autolaunch.Points.Trade`). Nothing reads it to resend, restore or
  hold back a transaction.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_trades"
    repo Autolaunch.Repo
  end

  actions do
    read :read do
      primary? true
    end

    # The same transaction sent again keeps its first record.
    create :report do
      accept [:chain_id, :transaction_hash, :wallet]
      change set_attribute(:human_account_id, actor(:human_account_id))

      upsert? true
      upsert_identity :transaction
      upsert_condition expr(false)
      return_skipped_upsert? true

      emit Autolaunch.Signals, :trade_reported, fields: [site_trade_id: :id]
    end
  end

  policies do
    policy action(:report) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action(:read) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :chain_id, :integer, allow_nil?: false, public?: true

    attribute :transaction_hash, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/]

    attribute :wallet, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :human_account_id, :integer, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :transaction, [:chain_id, :transaction_hash]
  end
end
