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
      label: "Sign in"
    }
  end

  def account_control(%__MODULE__{principal: {:human, account}}) do
    %AccountControl{
      kind: :signed_in,
      label: PublicIdentity.label(account),
      avatar_src: PublicIdentity.avatar_src(account),
      wallet_address: account.wallet_address
    }
  end

  @doc """
  The account control while a sign-in could not be read just then: neither Sign
  in nor a name, since the person may well still be signed in. The page says
  something didn't load instead.
  """
  def unreadable_account_control,
    do: %AccountControl{kind: :unreadable, label: "Something didn’t load"}
end
