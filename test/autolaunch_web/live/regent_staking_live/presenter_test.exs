defmodule AutolaunchWeb.RegentStakingLive.PresenterTest do
  use ExUnit.Case, async: true

  alias AutolaunchWeb.RegentStakingLive.Presenter

  test "translates staking action errors" do
    assert Presenter.action_error(:unauthorized) == "Connect a wallet first."
    assert Presenter.action_error(:operator_required) == "Use an authorized operator wallet."
    assert Presenter.action_error(:unknown) == "Staking action could not be prepared."
  end

  test "chooses the configured chain label" do
    assert Presenter.chain_label(%{chain_label: "Base"}) == "Base"
    assert Presenter.chain_label(nil) == "Not configured"
    assert Presenter.chain_label(%{}) == "Base"
  end
end
