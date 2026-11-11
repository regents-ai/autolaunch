defmodule Autolaunch.Points.Accounts do
  @moduledoc "Verified account lookups supplied to the shared Points package."
  @behaviour RegentPoints.Accounts

  require Ash.Query

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanAccount
  alias Autolaunch.Actors.System
  alias Autolaunch.PublicIdentity

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

  # What the board shows of each account: its name or wallet, and its pictures.
  @impl true
  def people([]), do: {:ok, %{}}

  def people(ids) do
    query =
      HumanAccount
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load([:display_name, :ens_name, :ens_avatar_url])

    with {:ok, accounts} <- Ash.read(query, actor: %System{}) do
      {:ok,
       Map.new(accounts, fn account ->
         {account.id,
          %{
            name: PublicIdentity.listed_name(account),
            wallet: PublicIdentity.wallet(account),
            ens_name: PublicIdentity.ens_name(account),
            squares: PublicIdentity.squares(account),
            picture: PublicIdentity.picture(account)
          }}
       end)}
    end
  end
end
