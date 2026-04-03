defmodule Autolaunch.Launch.External.SocialAccount do
  @moduledoc false
  use Autolaunch.Schema

  schema "agent_social_accounts" do
    field :owner_address, :string
    field :agent_id, :string
    field :provider, :string
    field :handle, :string
    field :profile_url, :string
    field :provider_subject, :string
    field :status, :string
    field :verified_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :owner_address,
      :agent_id,
      :provider,
      :handle,
      :profile_url,
      :provider_subject,
      :status,
      :verified_at
    ])
    |> validate_required([:owner_address, :agent_id, :provider, :status])
    |> validate_length(:agent_id, max: 255)
    |> validate_length(:provider, max: 32)
    |> validate_length(:handle, max: 255)
    |> validate_length(:profile_url, max: 500)
    |> validate_length(:provider_subject, max: 255)
    |> unique_constraint([:agent_id, :provider],
      name: :agent_social_accounts_agent_provider_unique
    )
    |> unique_constraint([:provider, :provider_subject],
      name: :agent_social_accounts_provider_subject_unique
    )
  end
end
