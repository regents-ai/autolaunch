defmodule Autolaunch.Accounts.Signals do
  @moduledoc """
  What accounts tell the rest of the site, as Ash signals. Each is emitted in
  the transaction of the write that made it, so a listener with the default
  delivery commits or rolls back with it. Points offers each to Regent Points
  (`Autolaunch.Points.Award`).

    * `:account_registered`: a sign-in created the person's shared Regent
      account (`Autolaunch.Accounts.HumanAccount` `:register_verified`). A
      later sign-in to the same account, here or on another Regent site,
      emits nothing.
    * `:social_linked`: a sign-in linked an X, GitHub or Farcaster account
      Privy lists to the person's account, or replaced the one linked for that
      provider (`Autolaunch.Accounts.LinkedIdentity` `:upsert_verified`). A
      sign-in that only refreshes the same link emits nothing, and neither
      does an ENS name.
    * `:x_connected`: the Account page's X button connected an X account, as
      the person's own (`:profile`) or their company's (`:company`)
      (`Autolaunch.Accounts.XConnection` `:complete_attempt`). Connecting
      again, the same X account or another, emits it again.
  """

  use Ash.Signals

  signals do
    signal :account_registered do
      argument :account_id, :integer, allow_nil?: false
    end

    signal :social_linked do
      argument :provider, :atom, allow_nil?: false
      argument :subject, :string, allow_nil?: false
    end

    signal :x_connected do
      argument :role, :atom, allow_nil?: false
      argument :x_user_id, :string, allow_nil?: false
    end
  end
end
