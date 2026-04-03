defmodule Autolaunch.Portfolio.Snapshot do
  @moduledoc false
  use Autolaunch.Schema

  alias Autolaunch.Accounts.HumanUser

  schema "autolaunch_portfolio_snapshots" do
    field :status, :string, default: "pending"
    field :launched_tokens_payload, {:array, :map}, default: []
    field :staked_tokens_payload, {:array, :map}, default: []
    field :refreshed_at, :utc_datetime_usec
    field :refresh_started_at, :utc_datetime_usec
    field :next_manual_refresh_at, :utc_datetime_usec
    field :error_message, :string

    belongs_to :human, HumanUser

    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :human_id,
      :status,
      :launched_tokens_payload,
      :staked_tokens_payload,
      :refreshed_at,
      :refresh_started_at,
      :next_manual_refresh_at,
      :error_message
    ])
    |> validate_required([:human_id, :status])
    |> validate_inclusion(:status, ["pending", "running", "ready", "error"])
    |> unique_constraint(:human_id)
  end
end
