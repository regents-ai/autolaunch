defmodule Autolaunch.AccessContextTest do
  use ExUnit.Case, async: true

  alias Autolaunch.AccessContext

  @wallet "0x1111111111111111111111111111111111111111"

  test "anonymous account control exposes only sign in" do
    assert %{kind: :sign_in, label: "Sign In", profile_path: nil, settings_path: nil} =
             AccessContext.account_control(AccessContext.anonymous())
  end

  test "a signed human without a Regent has settings but no profile target" do
    account = %{wallet_address: @wallet, display_name: "Account label"}

    assert %{
             kind: :signed_in,
             label: "Account label",
             profile_path: nil,
             settings_path: "/settings",
             wallet_address: @wallet
           } =
             AccessContext.account_control(AccessContext.human(account))
  end
end
