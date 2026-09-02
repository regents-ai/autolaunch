defmodule Autolaunch.PublicIdentityTest do
  use ExUnit.Case, async: true

  alias Autolaunch.PublicIdentity

  test "public labels resolve profile choice, Regent nameclaim, ENS, then abbreviated wallet" do
    identity = %{
      display_name: "Profile choice",
      regent_nameclaim: "atlas.regent.eth",
      ens_name: "atlas.eth",
      wallet_address: "0x111111111111111111111111111111111111a1b2"
    }

    assert PublicIdentity.label(identity) == "Profile choice"
    assert PublicIdentity.label(%{identity | display_name: " "}) == "atlas.regent.eth"

    assert PublicIdentity.label(%{identity | display_name: nil, regent_nameclaim: nil}) ==
             "atlas.eth"

    assert PublicIdentity.label(%{
             identity
             | display_name: nil,
               regent_nameclaim: nil,
               ens_name: nil
           }) == "0x1111…a1b2"
  end

  test "wallet avatars are local, deterministic, and address-specific" do
    first =
      PublicIdentity.avatar_data_uri(%{
        wallet_address: "0x111111111111111111111111111111111111a1b2"
      })

    retry =
      PublicIdentity.avatar_data_uri(%{
        wallet_address: "0x111111111111111111111111111111111111A1B2"
      })

    other =
      PublicIdentity.avatar_data_uri(%{
        wallet_address: "0x222222222222222222222222222222222222a1b2"
      })

    assert first == retry
    assert first != other
    assert "data:image/svg+xml;base64," <> encoded = first
    assert Base.decode64!(encoded) =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
    refute first =~ "0x1111"
    assert PublicIdentity.avatar_data_uri(%{wallet_address: nil}) == nil
  end
end
