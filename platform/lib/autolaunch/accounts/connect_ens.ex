defmodule Autolaunch.Accounts.ConnectEns do
  @moduledoc "Verifies a creator-controlled ENS name before publishing its connection."
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{EnsIdentity, SessionAuthority}
  alias Autolaunch.Actors.{Human, System}
  alias AutolaunchWeb.{ReadFailedError, ReadFailure}
  alias RegentChain.Address

  @refusals %{
    try_again: "That did not go through. Try again in a moment.",
    name_taken: "That ENS name is already connected to another account.",
    signed_out: "Sign in again to connect ENS.",
    not_controlled:
      "Use an ENS name controlled by your signed-in wallet that also resolves to it. Check the name and try again."
  }

  # A refusal is the name argument's error, with words a person can act on
  # (`AutolaunchWeb.CreatorConnectionsComponent` shows them as they are).
  def run(input, %{actor: %Human{human_account_id: id}}) do
    lease = input.context[:session_lease]

    with %{lineage: lineage, account_id: ^id} <- lease,
         {:ok, %{} = account} <- leased(lineage, id),
         {:ok, details} <- read(input.arguments.name),
         true <- controls?(details, account),
         {:ok, identity} <- record_name(lineage, id, details) do
      {:ok, %{name: identity.username, address: details.eth_address}}
    else
      {:error, reason} when reason in [:try_again, :name_taken, :signed_out] -> refused(reason)
      _ -> refused(:not_controlled)
    end
  end

  def run(_, _), do: refused(:signed_out)

  defp refused(reason),
    do:
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :name,
         message: Map.fetch!(@refusals, reason)
       )}

  # As on a page (`AutolaunchWeb.ReadFailure`): a sign-in read that lost its
  # connection is a try-again, never a name that doesn't fit, and any other
  # failure is a real error. `SessionAuthority` logged it.
  defp leased(lineage, id) do
    case SessionAuthority.leased_account(lineage, id) do
      {:ok, nil} -> {:error, :signed_out}
      {:error, error} -> failed(error)
      leased -> leased
    end
  end

  @doc """
  Saves `details`, a name already read and checked, as the leased account's ENS
  connection, under the lease read again now (`SessionAuthority.transact_lease/3`):
  `{:ok, identity}`; `{:error, :name_taken}` when another account has the name,
  which no retry changes; `{:error, :signed_out}` once the sign-in has ended;
  `{:error, :wallet_changed}` when the account's wallet no longer controls it;
  and `{:error, :try_again}` when the connection was lost. Anything else raises.
  """
  def record_name(lineage, id, details) do
    case SessionAuthority.transact_lease(lineage, id, &record(details, &1)) do
      {:error, :stale_authority} -> {:error, :signed_out}
      {:error, :wallet_changed} -> {:error, :wallet_changed}
      {:error, error} -> if name_taken?(error), do: {:error, :name_taken}, else: failed(error)
      recorded -> recorded
    end
  end

  # Another account's connection to the same name
  # (`LinkedIdentity`'s `unique_subject_per_provider`). A save that fails inside
  # the lease's transaction rolls it back with its changeset, which carries the
  # same errors.
  defp name_taken?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &match?(%{field: field} when field in [:provider, :subject], &1))

  defp name_taken?(_error), do: false

  defp failed(error) do
    if ReadFailure.lost_connection?(error), do: {:error, :try_again}, else: raise(ReadFailedError)
  end

  # A save that fails for any reason but a taken name is logged here, by kind
  # and module only; a failed sign-in read was logged where it was read.
  defp record(details, account) do
    if controls?(details, account) do
      details |> upsert(account) |> logged()
    else
      {:error, :wallet_changed}
    end
  end

  defp logged({:error, error} = failed) do
    unless name_taken?(error), do: ReadFailure.log("ENS connection save", error)
    failed
  end

  defp logged(saved), do: saved

  defp upsert(details, account) do
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
