defmodule Autolaunch.Accounts.ConnectEns do
  @moduledoc "Verifies a creator-controlled ENS name before publishing its connection."
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{EnsIdentity, SessionAuthority}
  alias Autolaunch.Actors.{Human, System}
  alias RegentChain.Address

  def run(input, %{actor: %Human{human_account_id: id}}) do
    lease = input.context[:session_lease]

    with %{lineage: lineage, account_id: ^id} <- lease,
         {:ok, %{} = account} <- leased(lineage, id),
         {:ok, details} <- read(input.arguments.name),
         true <- controls?(details, account),
         {:ok, identity} <- recorded(lineage, id, details) do
      {:ok, %{name: identity.username, address: details.eth_address}}
    else
      {:error, :try_again} ->
        {:error, "That did not go through. Try again in a moment."}

      _ ->
        {:error,
         "Use an ENS name controlled by your signed-in wallet that also resolves to it. Check the name and try again."}
    end
  end

  def run(_, _), do: {:error, "Sign in again to connect ENS."}

  # A sign-in that could not be read just then (`SessionAuthority` logged it),
  # or a save that failed, is a try-again, never a name that doesn't fit.
  defp leased(lineage, id) do
    case SessionAuthority.leased_account(lineage, id) do
      {:error, _unread} -> {:error, :try_again}
      leased -> leased
    end
  end

  defp recorded(lineage, id, details) do
    case SessionAuthority.transact_lease(lineage, id, &record(details, &1)) do
      {:error, reason} when reason in [:wallet_changed, :stale_authority] -> {:error, reason}
      {:error, _failed} -> {:error, :try_again}
      recorded -> recorded
    end
  end

  defp record(details, account) do
    if controls?(details, account) do
      Accounts.upsert_linked_identity(
        :ens,
        details.normalized_name,
        details.normalized_name,
        details.normalized_name,
        DateTime.utc_now(),
        %{
          "chain_id" => 1,
          "resolver" => details.resolver_address,
          "wallet" => String.downcase(details.eth_address)
        },
        account.id,
        actor: %System{}
      )
    else
      {:error, :wallet_changed}
    end
  end

  defp read(name) do
    AgentEns.read_name(%{
      ens_name: name,
      chain_id: 1,
      rpc_url: EnsIdentity.rpc_url(),
      include_contenthash?: false
    })
  end

  # A forward record alone is not identity evidence: anyone could point a name
  # at someone else's wallet. Require control and resolution to the same signer.
  defp controls?(details, account) do
    Address.equal?(details.manager, account.wallet_address) and
      Address.equal?(details.eth_address, account.wallet_address)
  end
end
