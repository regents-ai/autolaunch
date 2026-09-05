defmodule Autolaunch.VerifiedPrivyIdentity do
  @moduledoc false

  @enforce_keys [:privy_user_id, :session_id, :wallet_addresses]
  defstruct [:privy_user_id, :session_id, :wallet_address, :wallet_addresses, linked_socials: []]

  @type linked_social :: %{
          provider: :x | :github | :farcaster,
          subject: String.t(),
          username: String.t() | nil,
          display_name: String.t() | nil
        }

  @type t :: %__MODULE__{
          privy_user_id: String.t(),
          session_id: String.t(),
          wallet_address: String.t() | nil,
          wallet_addresses: [String.t()],
          linked_socials: [linked_social()]
        }
end
