defmodule Autolaunch.LaunchOperations do
  @moduledoc """
  The one private transition boundary for `LaunchOperation`.

  Every durable write runs inside `SessionAuthority.transact_lease/3` as the
  outermost transaction, so a review transition cannot outlive a concurrent
  logout, revocation or lapse of provider evidence. The owner comes from the
  account that callback locked rather than an actor captured earlier.

  Provider reads happen before these calls. Only the resulting row write happens
  inside the lock, and the row is taken `FOR UPDATE` first, so two sockets racing
  the same dispatch serialize and exactly one of them wins.

  Reading the open operation is the one path that needs no lease: it reads the
  owning account's own row and writes nothing.
  """

  require Ash.Query

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Address
  alias Autolaunch.LaunchOperation

  @actor %System{}
  @domain Autolaunch

  @type lease :: %{lineage: String.t(), account_id: integer()}

  @doc "Runs `callback` against the account the mounted lease locks, or refuses to write at all."
  @spec transact(lease(), (Ash.Resource.record() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transact(%{lineage: lineage, account_id: account_id}, callback) do
    case SessionAuthority.transact_lease(lineage, account_id, callback) do
      {:error, :stale_authority} -> unavailable(:session_unavailable)
      result -> result
    end
  end

  @doc "Commits the reviewed envelope as the operation the wallet handoff will need."
  @spec create(Ash.Resource.record(), map()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def create(account, attributes) do
    LaunchOperation
    |> Ash.Changeset.for_create(
      :prepare,
      Map.put(attributes, :human_account_id, account.id),
      domain: @domain,
      actor: @actor
    )
    |> Ash.create(actor: @actor)
  end

  @doc "One operation of this account, taken `FOR UPDATE` when it is about to move."
  @spec fetch(integer(), String.t(), boolean()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def fetch(account_id, action_id, lock?) do
    LaunchOperation
    |> Ash.Query.new(domain: @domain)
    |> Ash.Query.filter(action_id == ^action_id and human_account_id == ^account_id)
    |> locked(lock?)
    |> Ash.read_one(domain: @domain, actor: @actor)
    |> case do
      {:ok, nil} -> unavailable(:launch_operation_not_found)
      other -> other
    end
  end

  @doc "The account's open launch operation, or `nil`."
  @spec open(integer(), boolean()) :: {:ok, Ash.Resource.record() | nil} | {:error, term()}
  def open(account_id, lock?) do
    LaunchOperation
    |> Ash.Query.for_read(:open, %{human_account_id: account_id}, domain: @domain, actor: @actor)
    |> locked(lock?)
    |> Ash.read_one(domain: @domain)
  end

  @doc "Applies one named transition to a locked row."
  @spec update(Ash.Resource.record(), atom(), map()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def update(operation, action, input \\ %{}) do
    operation
    |> Ash.Changeset.for_update(action, input, domain: @domain, actor: @actor)
    |> Ash.update(actor: @actor)
  end

  @doc "The signer is the account's signed-in wallet right now, proved inside the locked transaction."
  @spec signer_matches(Ash.Resource.record(), String.t()) :: :ok | {:error, term()}
  def signer_matches(%{wallet_address: wallet}, signer) do
    if Address.equal?(wallet, signer),
      do: :ok,
      else: unavailable(:wrong_signer)
  end

  @doc """
  A typed Ash error, so the refusal survives the action's error class.

  The presenter can then name the fact that actually stopped the launch instead
  of showing a generic failure.
  """
  @spec unavailable(atom()) :: {:error, Ash.Error.Invalid.Unavailable.t()}
  def unavailable(reason),
    do:
      {:error, Ash.Error.Invalid.Unavailable.exception(resource: LaunchOperation, reason: reason)}

  defp locked(query, true), do: Ash.Query.lock(query, :for_update)
  defp locked(query, false), do: query
end
