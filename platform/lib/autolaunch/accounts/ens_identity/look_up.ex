defmodule Autolaunch.Accounts.EnsIdentity.LookUp do
  @moduledoc """
  Reads the wallet's verified ENS name and picture before the row is written.

  The chain is read before the update and outside any transaction. A name is
  kept only when it resolves back to the same wallet, and a picture only when
  the ENS avatar service answers with one (`AgentEns.PrimaryName`). A failed
  read fails the action, so the job retries with backoff; a server with no
  Ethereum endpoint cancels it.
  """

  use Ash.Resource.Change

  alias AgentEns.PrimaryName
  alias AshOban.Errors.CancelJob
  alias Autolaunch.Accounts.EnsIdentity

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      wallet = changeset.data.wallet_address

      case look_up(wallet) do
        {:ok, identity} ->
          changeset
          # The wallet this answer is for, should a sign-in have changed it since.
          |> Ash.Changeset.force_change_attribute(:wallet_address, wallet)
          |> Ash.Changeset.force_change_attribute(:ens_name, identity[:name])
          |> Ash.Changeset.force_change_attribute(:ens_avatar_url, identity[:avatar_url])
          |> Ash.Changeset.force_change_attribute(:lookup_state, :done)

        {:cancel, reason} ->
          Ash.Changeset.add_error(changeset, CancelJob.exception(reason: reason))

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, "ENS lookup failed: #{inspect(reason)}")
      end
    end)
  end

  defp look_up(wallet) do
    case EnsIdentity.rpc_url() do
      nil ->
        {:cancel, :no_ethereum_endpoint}

      rpc_url ->
        with {:ok, identity} <- PrimaryName.verified_primary_identity(wallet, rpc_url: rpc_url),
             do: {:ok, identity || %{}}
    end
  end
end
