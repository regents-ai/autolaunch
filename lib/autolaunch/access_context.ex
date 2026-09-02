defmodule Autolaunch.AccessContext do
  @moduledoc "Principal-aware access context for public shell routes."

  alias __MODULE__.AccountControl
  alias Autolaunch.PublicIdentity

  @enforce_keys [:principal, :capabilities]
  defstruct @enforce_keys

  def anonymous, do: %__MODULE__{principal: :anonymous, capabilities: [:view_public]}

  def human(account), do: %__MODULE__{principal: {:human, account}, capabilities: [:view_public]}

  def account_control(%__MODULE__{principal: :anonymous}) do
    %AccountControl{
      kind: :sign_in,
      label: "Sign In",
      profile_path: nil,
      settings_path: nil
    }
  end

  def account_control(%__MODULE__{principal: {:human, account}}) do
    %AccountControl{
      kind: :signed_in,
      label: PublicIdentity.label(account),
      profile_path: nil,
      settings_path: "/settings",
      avatar_data_uri: PublicIdentity.avatar_data_uri(account),
      wallet_address: account.wallet_address || List.first(account.wallet_addresses || [])
    }
  end
end
