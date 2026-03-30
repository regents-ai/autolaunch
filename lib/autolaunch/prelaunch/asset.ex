defmodule Autolaunch.Prelaunch.Asset do
  @moduledoc false
  use Autolaunch.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "autolaunch_prelaunch_assets" do
    field :asset_id, :string
    field :privy_user_id, :string
    field :file_name, :string
    field :media_type, :string
    field :storage_path, :string
    field :source_url, :string
    field :public_url, :string
    field :byte_size, :integer
    field :sha256, :string

    timestamps()
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :asset_id,
      :privy_user_id,
      :file_name,
      :media_type,
      :storage_path,
      :source_url,
      :public_url,
      :byte_size,
      :sha256
    ])
    |> validate_required([:asset_id, :privy_user_id, :file_name, :media_type, :public_url])
    |> unique_constraint(:asset_id)
  end
end
