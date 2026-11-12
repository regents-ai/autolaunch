defmodule Autolaunch.Stocks.LaunchOperations do
  @moduledoc """
  What every wallet action shares: the signed-in wallet a review binds to
  (`signed_in_wallet/3`, used by Revstake launches, bids, settlements, swaps
  and every Stocks and Robinhood action), and for Stocks and Robinhood the
  refusal each one answers with and the one private write of
  `Autolaunch.Stocks.LaunchOperation`.

  Every durable write runs inside `SessionAuthority.transact_lease/3` against the
  account that callback locked, exactly as the Agent launch boundary does.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Stocks.LaunchOperation
  alias RegentChain.Address

  @actor %System{}
  @domain Autolaunch
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @type lease :: %{lineage: String.t(), account_id: integer()}

  @doc """
  The signed-in person, their account and the wallet their action binds to:
  `address` has to be one of the wallets the account the session lease names
  links, read inside the lease now, never a guess. A refusal names `resource`,
  the record the action reviews.
  """
  @spec signed_in_wallet(term(), keyword(), module()) ::
          {:ok,
           %{actor: Human.t(), account: Ash.Resource.record(), signer: String.t(), lease: lease()}}
          | {:error, term()}
  def signed_in_wallet(address, opts, resource \\ LaunchOperation) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- address(address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         :ok <- linked(account, signer) do
      {:ok, %{actor: actor, account: account, signer: signer, lease: lease}}
    else
      {:refused, reason} -> refusal(resource, reason)
      unread -> unread
    end
  end

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

  @spec signer_matches(Ash.Resource.record(), String.t()) :: :ok | {:error, term()}
  def signer_matches(account, signer) do
    case linked(account, signer) do
      :ok -> :ok
      {:refused, reason} -> unavailable(reason)
    end
  end

  @doc "A chain read's answer, with every passing fault refused as `:chain_unavailable`."
  @spec chain({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def chain({:ok, value}), do: {:ok, value}
  def chain({:error, reason}) when reason in @transient, do: unavailable(:chain_unavailable)
  def chain({:error, reason}), do: unavailable(reason)

  @spec unavailable(atom()) :: {:error, Ash.Error.Invalid.Unavailable.t()}
  def unavailable(reason), do: refusal(LaunchOperation, reason)

  defp refusal(resource, reason),
    do: {:error, Ash.Error.Invalid.Unavailable.exception(resource: resource, reason: reason)}

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> {:refused, :authentication_required}
    end
  end

  defp address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> {:refused, :invalid_address}
    end
  end

  defp lease(opts) do
    case Keyword.get(opts, :context) do
      %{session_lease: %{lineage: lineage, account_id: account_id}}
      when is_binary(lineage) and is_integer(account_id) ->
        {:ok, %{lineage: lineage, account_id: account_id}}

      _absent ->
        {:refused, :session_lease_required}
    end
  end

  # A lineage that has been revoked, rebound or whose provider evidence has
  # lapsed resolves to no account.
  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      {:ok, nil} -> {:refused, :session_unavailable}
      result -> result
    end
  end

  # The lease and the acting human have to name one account.
  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: {:refused, :session_unavailable}

  defp linked(%{wallet_addresses: wallets}, signer) do
    if Enum.any?(wallets, &Address.equal?(&1, signer)),
      do: :ok,
      else: {:refused, :wrong_signer}
  end
end
