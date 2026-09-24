defmodule Autolaunch.Accounts.ConnectEns do
  @moduledoc "Verifies a creator-controlled ENS name before publishing its connection."
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.Address

  def run(input, %{actor: %Human{human_account_id: id}}) do
    lease = input.context[:session_lease]

    with %{lineage: lineage, account_id: ^id} <- lease,
         account when not is_nil(account) <- SessionAuthority.leased_account(lineage, id),
         {:ok, details} <- read(input.arguments.name),
         true <- controls?(details, account),
         {:ok, identity} <-
           SessionAuthority.transact_lease(lineage, id, fn current ->
             if controls?(details, current) do
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
                 id,
                 actor: %System{}
               )
             else
               {:error, :wallet_changed}
             end
           end) do
      {:ok, %{name: identity.username, address: details.eth_address}}
    else
      _ ->
        {:error,
         "Use an ENS name controlled by your signed-in wallet that also resolves to it. Check the name and try again."}
    end
  end

  def run(_, _), do: {:error, "Sign in again to connect ENS."}

  defp read(name) do
    AgentEns.read_name(%{
      ens_name: name,
      chain_id: 1,
      rpc_url: Application.get_env(:autolaunch, :ens_rpc_url, "https://ethereum.publicnode.com"),
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
