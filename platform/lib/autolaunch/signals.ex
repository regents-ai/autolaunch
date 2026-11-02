defmodule Autolaunch.Signals do
  @moduledoc """
  What this site's launches tell the rest of the site, as Ash signals. Each is
  emitted in the save's own transaction, so a listener with the default
  delivery commits or rolls back with it. Points offers each to Regent Points
  (`Autolaunch.Points.Award`).

    * `:launch_listed`: an auction was first recorded for the account whose
      review carried out its launch.
    * `:launch_graduated`: such an auction graduated.
    * `:bid_recorded`: a confirmed bid was saved whose wallet belonged to an
      account, or its paired agent, when it bid.
    * `:bid_settled`: the same for a confirmed withdraw or claim of a bid.
    * `:token_staked`: a stake was saved whose wallet belonged to an account,
      or its paired agent, when it staked.
    * `:trade_reported`: the wallet handed back a swap sent from the site's
      trade panel (`Autolaunch.SiteTrade`).
  """

  use Ash.Signals

  signals do
    signal :launch_listed do
      argument :auction_id, :uuid, allow_nil?: false
    end

    signal :launch_graduated do
      argument :auction_id, :uuid, allow_nil?: false
    end

    signal :bid_recorded do
      argument :auction_id, :uuid, allow_nil?: false
      argument :bid_id, :string, allow_nil?: false
    end

    signal :bid_settled do
      argument :auction_id, :uuid, allow_nil?: false
      argument :bid_id, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:exit, :claim]]
    end

    signal :token_staked do
      argument :token_id, :uuid, allow_nil?: false
      argument :transaction_hash, :string, allow_nil?: false
      argument :log_index, :integer, allow_nil?: false
    end

    signal :trade_reported do
      argument :site_trade_id, :uuid, allow_nil?: false
    end
  end
end
