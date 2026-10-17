defmodule Autolaunch.Points.Accounts do
  @moduledoc "Verified account lookups supplied to the shared Points package."
  @behaviour RegentPoints.Accounts
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  @impl true
  def human(id), do: Accounts.points_account!(id, actor: %System{})
  @impl true
  def agent_names(_id, []), do: {:ok, %{}}

  def agent_names(id, ids) do
    with {:ok, account} <- Accounts.points_account(id, actor: %System{}),
         {:ok, %{rows: rows}} <-
           Autolaunch.Repo.query(
             "SELECT id::text, name FROM regent_agents.pairing_history WHERE privy_user_id = $1 AND id::text = ANY($2::text[])",
             [account.privy_user_id, ids]
           ) do
      {:ok, Map.new(rows, fn [id, name] -> {id, name} end)}
    else
      _ -> {:error, :account_unavailable}
    end
  end
end
