defmodule Autolaunch.Stocks.LaunchOperations do
  @moduledoc """
  The one private transition boundary for `Autolaunch.Stocks.LaunchOperation`.

  Every durable write runs inside `SessionAuthority.transact_lease/3` against the
  account that callback locked, exactly as the Agent launch boundary does. The
  row is taken `FOR UPDATE` before it moves, so two sockets racing one step
  serialize and exactly one wins.
  """

  require Ash.Query

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks.LaunchOperation

  @actor %System{}
  @domain Autolaunch

  @type lease :: %{lineage: String.t(), account_id: integer()}

  @spec transact(lease(), (Ash.Resource.record() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transact(%{lineage: lineage, account_id: account_id}, callback) do
    case SessionAuthority.transact_lease(lineage, account_id, callback) do
      {:error, :stale_authority} -> unavailable(:session_unavailable)
      result -> result
    end
  end

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

  @spec open(integer(), boolean()) :: {:ok, Ash.Resource.record() | nil} | {:error, term()}
  def open(account_id, lock?) do
    LaunchOperation
    |> Ash.Query.for_read(:open, %{human_account_id: account_id}, domain: @domain, actor: @actor)
    |> locked(lock?)
    |> Ash.read_one(domain: @domain)
  end

  @spec update(Ash.Resource.record(), atom(), map()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def update(operation, action, input \\ %{}) do
    operation
    |> Ash.Changeset.for_update(action, input, domain: @domain, actor: @actor)
    |> Ash.update(actor: @actor)
  end

  @doc "Binds the first valid hash of the one `launch` step; an exact replay is a no-op."
  @spec bind(Ash.Resource.record(), :launch, String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def bind(%{launch_transaction_hash: hash} = operation, :launch, hash), do: {:ok, operation}

  def bind(%{launch_transaction_hash: nil} = operation, :launch, hash),
    do: update(operation, bind_action(operation), %{launch_transaction_hash: hash})

  def bind(_operation, :launch, _hash), do: unavailable(:submitted_hash_conflict)

  defp bind_action(%{terminal_at: nil}), do: :bind_hash
  defp bind_action(_terminal), do: :attach_late_hash

  @spec signer_matches(Ash.Resource.record(), String.t()) :: :ok | {:error, term()}
  def signer_matches(%{wallet_addresses: wallets}, signer) do
    if Enum.any?(wallets || [], &Address.equal?(&1, signer)),
      do: :ok,
      else: unavailable(:wrong_signer)
  end

  @spec unavailable(atom()) :: {:error, Ash.Error.Invalid.Unavailable.t()}
  def unavailable(reason),
    do:
      {:error, Ash.Error.Invalid.Unavailable.exception(resource: LaunchOperation, reason: reason)}

  defp locked(query, true), do: Ash.Query.lock(query, :for_update)
  defp locked(query, false), do: query
end
