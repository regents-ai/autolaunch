defmodule Autolaunch.LaunchOperations do
  @moduledoc """
  The one private transition boundary for `LaunchOperation`.

  Every durable write runs inside `SessionAuthority.transact_lease/3` as the
  outermost transaction, so a claim, a hash bind or a settlement cannot outlive a
  concurrent logout, revocation or lapse of provider evidence. The owner comes
  from the account that callback locked rather than an actor captured earlier.

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

  @hash_attributes %{approval: :approval_transaction_hash, launch: :launch_transaction_hash}

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

  @doc """
  Binds the first valid hash for the step the browser was actually sent.

  An exact replay is an authority no-op so a retrying browser cannot fail, a
  different hash is refused rather than overwriting the submitted identity, and a
  hash recovered after the operation ended attaches without reopening it. The
  step travels with the hash and has to be the one the row is on, so a callback
  delayed past an advance can never land in the other step's column.
  """
  @spec bind(Ash.Resource.record(), :approval | :launch, String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def bind(operation, step, hash) do
    attribute = Map.fetch!(@hash_attributes, step)

    case Map.fetch!(operation, attribute) do
      ^hash -> {:ok, operation}
      nil -> bind_step(operation, step, attribute, hash)
      _different -> unavailable(:submitted_hash_conflict)
    end
  end

  defp bind_step(%{step: step} = operation, step, attribute, hash),
    do: update(operation, bind_action(operation), %{attribute => hash})

  defp bind_step(_operation, _step, _attribute, _hash), do: unavailable(:submitted_step_mismatch)

  defp bind_action(%{terminal_at: nil}), do: :bind_hash
  defp bind_action(_terminal), do: :attach_late_hash

  @doc "The hash bound for one step of an operation, or `nil`."
  @spec hash(map(), :approval | :launch) :: String.t() | nil
  def hash(operation, step), do: Map.get(operation, Map.fetch!(@hash_attributes, step))

  @doc "The account really holds this wallet right now, proved inside the locked transaction."
  @spec signer_matches(Ash.Resource.record(), String.t()) :: :ok | {:error, term()}
  def signer_matches(%{wallet_addresses: wallets}, signer) do
    if Enum.any?(wallets || [], &Address.equal?(&1, signer)),
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
