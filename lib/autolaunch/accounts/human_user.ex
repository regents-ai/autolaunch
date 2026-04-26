defmodule Autolaunch.Accounts.HumanUser do
  @moduledoc false
  use Autolaunch.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "autolaunch_human_users" do
    field :privy_user_id, :string
    field :wallet_address, :string
    field :wallet_addresses, {:array, :string}, default: []
    field :xmtp_inbox_id, :string
    field :display_name, :string
    field :role, :string, default: "user"

    timestamps()
  end

  def changeset(human, attrs) do
    human
    |> cast(attrs, [
      :privy_user_id,
      :wallet_address,
      :wallet_addresses,
      :xmtp_inbox_id,
      :display_name,
      :role
    ])
    |> validate_required([:privy_user_id])
    |> validate_length(:display_name, max: 80)
    |> unique_constraint(:privy_user_id)
    |> unique_constraint(:xmtp_inbox_id)
  end
end
