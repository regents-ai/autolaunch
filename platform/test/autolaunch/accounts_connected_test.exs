defmodule Autolaunch.AccountsConnectedTest do
  @moduledoc """
  `Autolaunch.Accounts.connected?/1`, the one rule for whether a person has an
  account on show: a checked X account, a linked GitHub or a linked ENS. The
  create page asks a Revstake creator without one to type a warning, and a
  paired agent's launch answer carries `no_connections` for them.
  """
  use Autolaunch.DataCase, async: true

  alias Autolaunch.{Accounts, TestSupport}

  test "a person with nothing linked has no account on show" do
    refute Accounts.connected?(TestSupport.register_creator!().id)
  end

  test "a person whose X connection was begun and never checked has no account on show" do
    account = TestSupport.register_creator!()
    TestSupport.begin_x!(account, :profile)

    refute Accounts.connected?(account.id)
  end

  for {label, provider} <- [{"a checked X account", :x}, {"GitHub only", :github}, {"ENS only", :ens}] do
    test "a person with #{label} has an account on show" do
      account = TestSupport.register_creator!()
      TestSupport.connect!(account, unquote(provider))

      assert Accounts.connected?(account.id)
    end
  end
end
