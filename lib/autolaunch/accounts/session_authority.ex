defmodule Autolaunch.Accounts.SessionAuthority do
  @moduledoc """
  The durable authority behind one browser session lineage.

  The signed cookie carries only a random 32-byte lineage, its generation and
  the socket topic that the lineage alone determines. It never carries an
  account: identity comes from the locked row, so no browser can assert who it
  is. The row is keyed by the SHA-256 digest of the lineage, so a database
  reader can never rebuild a usable cookie.

  `/auth/csrf` commits an unbound generation-zero row that confers nothing until
  a verified sign-in binds it, and first bind and every same-account refresh
  advance the generation exactly once, so the cookie that carried the previous
  generation is stale for every later request and mount. Revocation is terminal.

  Every transition runs inside one transaction that inserts the operation's row
  when it is absent, locks it `FOR UPDATE`, and applies at most one legal
  change, so the absent-row race and the present-row race serialize identically.
  Provider verification, broadcasts, cookie writes and responses stay outside
  that lock.
  """

  use Ash.Resource,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Repo

  @actor %System{}
  @lineage_bytes 32
  @maximum_generation 9_223_372_036_854_775_807
  @topic_prefix "session_authority:"
  @canonical_keys ["session_lineage", "session_generation", "live_socket_id"]

  @typedoc "Everything a browser carries. There is no account here by design."
  @type claim :: %{lineage: String.t(), generation: non_neg_integer()}
  @type callback :: (Ash.Resource.record() -> {:ok, term()} | {:error, term()})

  postgres do
    table "session_authorities"
    repo Autolaunch.Repo

    check_constraints do
      check_constraint :generation, "session_authorities_generation_nonnegative",
        check: "generation >= 0",
        message: "generation must be nonnegative"
    end

    references do
      reference :human_account, on_delete: :restrict
    end
  end

  actions do
    # The primary read is what an atomic update re-reads the locked row through.
    defaults [:read]

    read :by_lineage_digest do
      get? true
      argument :lineage_digest, :binary, allow_nil?: false
      filter expr(lineage_digest == ^arg(:lineage_digest))
    end

    create :mint do
      accept []
      argument :lineage_digest, :binary, allow_nil?: false
      change set_attribute(:lineage_digest, arg(:lineage_digest))
    end

    update :bind do
      accept []
      argument :account_id, :integer, allow_nil?: false
      validate absent([:revoked_at, :human_account_id])
      change set_attribute(:human_account_id, arg(:account_id))
      change atomic_update(:generation, expr(generation + 1))
    end

    # Refresh cannot name an account, so a bound lineage can never change one.
    update :advance do
      accept []
      validate absent(:revoked_at)
      validate present(:human_account_id)
      change atomic_update(:generation, expr(generation + 1))
    end

    update :revoke do
      accept []
      validate absent(:revoked_at)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :lineage_digest, :binary, allow_nil?: false, sensitive?: true
    attribute :generation, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :revoked_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      attribute_type :integer
    end
  end

  identities do
    identity :unique_lineage_digest, [:lineage_digest]
  end

  @doc """
  The claim `session` carries, or `nil` when it carries none the server minted.

  Every canonical field must be present and internally consistent: the lineage
  is the exact unpadded base64url encoding of 32 bytes, the generation is inside
  the column's range, and the signed socket topic is the one this lineage
  determines. Anything else is malformed, never a weaker claim.
  """
  @spec claim(map() | nil) :: claim() | nil
  def claim(%{
        "session_lineage" => lineage,
        "session_generation" => generation,
        "live_socket_id" => socket_topic
      })
      when is_binary(lineage) and is_integer(generation) and generation >= 0 and
             generation <= @maximum_generation do
    with true <- canonical_lineage?(lineage),
         ^socket_topic <- topic(lineage) do
      %{lineage: lineage, generation: generation}
    else
      _malformed -> nil
    end
  end

  def claim(_session), do: nil

  @doc """
  Whether `session` is trying to carry a claim at all.

  A session holding any canonical field is making an authority statement, so a
  malformed one is refused rather than read as the absence of a claim.
  """
  @spec claim_shaped?(map() | nil) :: boolean()
  def claim_shaped?(session) when is_map(session),
    do: Enum.any?(@canonical_keys, &Map.has_key?(session, &1))

  def claim_shaped?(_session), do: false

  @doc "The canonical claim fields, and only those, that a response restores."
  @spec session(claim()) :: %{String.t() => term()}
  def session(%{lineage: lineage, generation: generation}),
    do: %{
      "session_lineage" => lineage,
      "session_generation" => generation,
      "live_socket_id" => topic(lineage)
    }

  @doc "Commits one unbound generation-zero lineage for a browser that carries none."
  @spec bootstrap() :: claim()
  def bootstrap do
    lineage = @lineage_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Ash.create!(__MODULE__, %{lineage_digest: digest(lineage)}, action: :mint, actor: @actor)
    %{lineage: lineage, generation: 0}
  end

  @doc """
  The exact-claim decision every request and connected mount resolves through.

  `{:ok, nil}` is a valid claim bound to no account; only `{:ok, account_id}`
  confers one, and that account is read from the row rather than the cookie.
  """
  @spec exact(claim() | nil) :: {:ok, integer() | nil} | {:error, :superseded | :reset}
  def exact(%{lineage: lineage} = claim) when is_binary(lineage) do
    row = lineage |> digest() |> row()

    case state(row, claim) do
      :exact -> {:ok, row.human_account_id}
      :ensurable -> {:ok, nil}
      other -> {:error, other}
    end
  end

  def exact(_claim), do: {:error, :reset}

  @doc """
  The `/auth/csrf` state matrix.

  A generation-zero claim whose row is absent is atomically ensured; a claim
  above generation zero whose row is absent fails closed and reports the
  invariant breach without the lineage that would identify the browser.
  """
  @spec renew(claim() | nil) :: {:bootstrap | :current, claim()} | {:error, :superseded | :reset}
  def renew(%{lineage: lineage, generation: generation} = claim) when is_binary(lineage) do
    case locked(claim, &{state(&1, claim), &1}) do
      {:exact, row} -> {:current, claim_at(lineage, row)}
      {:superseded, _row} -> {:error, :superseded}
      {:reset, nil} -> absent_row_breach(generation)
      {:reset, _row} -> {:error, :reset}
    end
  end

  def renew(_claim), do: {:bootstrap, bootstrap()}

  @doc """
  The one serialized transition a verified sign-in performs.

  An exact unbound claim binds to the verified account and an exact same-account
  claim refreshes, each advancing the generation once; the returned transition,
  not any cookie value, says which happened. A different account is a two-step
  cutover: the old lineage is revoked here and a replacement is only ever bound
  by a later request.
  """
  @spec sign_in(claim() | nil, integer()) ::
          {:ok, :bind | :refresh, claim()}
          | {:switch, String.t()}
          | {:error, :superseded | :reset}
  def sign_in(%{lineage: lineage} = claim, account_id)
      when is_binary(lineage) and is_integer(account_id) do
    locked(claim, fn row ->
      case state(row, claim) do
        :exact -> transition(row, lineage, account_id)
        other -> {:error, other}
      end
    end)
  end

  def sign_in(_claim, _account_id), do: {:error, :reset}

  @doc """
  Revokes a lineage terminally and idempotently, keeping the first revocation.

  Logout accepts any integrity-valid lineage, including one whose generation a
  concurrent refresh has already superseded, and ensures the row when a browser
  presents a lineage this node has never seen.
  """
  @spec revoke(claim() | nil) :: String.t() | nil
  def revoke(%{lineage: lineage}) when is_binary(lineage) do
    digest = digest(lineage)

    {:ok, _revoked} =
      Repo.transaction(fn ->
        ensure(digest, DateTime.utc_now())
        digest |> lock() |> revoke!()
      end)

    topic(lineage)
  end

  def revoke(_claim), do: nil

  @doc """
  The lineage and verified account an exactly current claim resolves to.

  `{nil, nil}` means the claim itself is not current; `{lineage, nil}` means it
  is current but confers no verified account.
  """
  @spec resolve(claim() | nil) :: {String.t() | nil, Ash.Resource.record() | nil}
  def resolve(claim) do
    case exact(claim) do
      {:ok, account_id} -> {claim.lineage, verified(account_id)}
      {:error, _lifecycle} -> {nil, nil}
    end
  end

  @doc """
  The verified account a mounted lease still resolves to, or `nil`.

  A same-account refresh advances the generation beneath a mounted socket, so a
  lease revalidates the lineage, its account, its revocation and the account's
  provider evidence rather than the generation it mounted with.
  """
  @spec leased_account(String.t(), integer()) :: Ash.Resource.record() | nil
  def leased_account(lineage, account_id) when is_binary(lineage) and is_integer(account_id) do
    if match?(%{revoked_at: nil, human_account_id: ^account_id}, lineage |> digest() |> row()),
      do: verified(account_id)
  end

  def leased_account(_lineage, _account_id), do: nil

  @doc """
  Runs `callback` against the account the exact claim locks.

  The lock, the revalidation and the callback share one repository transaction
  in one process, so a protected write cannot outlive a concurrent revocation,
  account switch, generation advance or lapse of provider evidence, and cannot
  survive its own failure.
  """
  @spec transact_exact(claim() | nil, callback()) :: {:ok, term()} | {:error, term()}
  def transact_exact(%{lineage: lineage} = claim, callback) when is_binary(lineage),
    do: guarded(lineage, &(state(&1, claim) == :exact), callback)

  def transact_exact(_claim, _callback), do: {:error, :stale_authority}

  @doc "The same primitive for a mounted lease, which tolerates same-account drift."
  @spec transact_lease(String.t(), integer(), callback()) :: {:ok, term()} | {:error, term()}
  def transact_lease(lineage, account_id, callback)
      when is_binary(lineage) and is_integer(account_id),
      do:
        guarded(
          lineage,
          &match?(%{revoked_at: nil, human_account_id: ^account_id}, &1),
          callback
        )

  def transact_lease(_lineage, _account_id, _callback), do: {:error, :stale_authority}

  @doc "The deterministic, lineage-stable topic every socket for a lineage mounts on."
  @spec topic(String.t()) :: String.t()
  def topic(lineage) when is_binary(lineage),
    do: @topic_prefix <> Base.url_encode64(digest(lineage), padding: false)

  # The four states an integrity-valid claim can hold against its row. A claim
  # ahead of its row, or above generation zero without one, is unrecoverable
  # rather than merely superseded.
  defp state(nil, %{generation: 0}), do: :ensurable
  defp state(nil, _claim), do: :reset
  defp state(%{revoked_at: revoked_at}, _claim) when not is_nil(revoked_at), do: :reset
  defp state(%{generation: generation}, %{generation: generation}), do: :exact

  defp state(%{generation: generation}, %{generation: claimed}) when claimed < generation,
    do: :superseded

  defp state(_row, _claim), do: :reset

  # Exhaustion is terminal rather than wrapping: the lineage is revoked and the
  # browser bootstraps a fresh one.
  defp transition(%{generation: @maximum_generation} = row, _lineage, _account_id) do
    revoke!(row)
    {:error, :reset}
  end

  defp transition(%{human_account_id: nil} = row, lineage, account_id),
    do: {:ok, :bind, mutate(row, lineage, %{account_id: account_id}, :bind)}

  defp transition(%{human_account_id: account_id} = row, lineage, account_id),
    do: {:ok, :refresh, mutate(row, lineage, %{}, :advance)}

  defp transition(row, lineage, _other_account_id) do
    revoke!(row)
    {:switch, topic(lineage)}
  end

  defp mutate(row, lineage, input, action) do
    row
    |> Ash.Changeset.for_update(action, input, actor: @actor)
    |> Ash.update!()
    |> then(&claim_at(lineage, &1))
  end

  defp revoke!(%{revoked_at: nil} = row),
    do: Ash.update!(row, %{}, action: :revoke, actor: @actor)

  defp revoke!(terminal), do: terminal

  # Bind and refresh may ensure the unbound generation-zero row the claim names,
  # so the absent-row order of a race takes the same lock as the present-row one.
  defp locked(%{lineage: lineage, generation: generation}, callback) do
    digest = digest(lineage)

    {:ok, result} =
      Repo.transaction(fn ->
        if generation == 0, do: ensure(digest, nil)
        digest |> lock() |> callback.()
      end)

    result
  end

  defp ensure(digest, revoked_at) do
    now = DateTime.utc_now()

    # Ash is bypassed here on purpose: this is the unconditional, idempotent seed
    # of a row that confers nothing until a locked transition binds it, and the
    # loser of a concurrent seed has to fall through to that lock silently rather
    # than raise. `on_conflict: :nothing` against the lineage-digest index is the
    # whole behaviour, so there is no change, policy or notification to run.
    Repo.insert_all(
      __MODULE__,
      [
        %{
          id: Ash.UUID.generate(),
          lineage_digest: digest,
          generation: 0,
          revoked_at: revoked_at,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: :lineage_digest
    )
  end

  defp lock(digest),
    do: digest |> lookup() |> Ash.Query.lock(:for_update) |> Ash.read_one!()

  defp row(digest), do: digest |> lookup() |> Ash.read_one!()

  defp lookup(digest),
    do:
      Ash.Query.for_read(__MODULE__, :by_lineage_digest, %{lineage_digest: digest}, actor: @actor)

  # Every protected write locks the authority row and then the account row, in
  # that one order, and reads the provider evidence only from behind the second
  # lock. A concurrent lapse therefore either waits for the callback to commit or
  # commits first and is seen, and two protected writes cannot deadlock.
  defp guarded(lineage, current?, callback) do
    Repo.transaction(fn ->
      row = lineage |> digest() |> lock()

      with true <- current?.(row),
           account when not is_nil(account) <- verified(row.human_account_id, :for_update) do
        commit(callback.(account))
      else
        _lapsed -> Repo.rollback(:stale_authority)
      end
    end)
  end

  defp verified(account_id, lock \\ nil)

  defp verified(nil, _lock), do: nil

  defp verified(account_id, lock) do
    with {:ok, account} when not is_nil(account) <-
           Accounts.get_human_account(account_id,
             actor: %Human{human_account_id: account_id},
             query: [lock: lock]
           ),
         true <- VerifiedSession.current?(account) do
      account
    else
      _lapsed -> nil
    end
  end

  defp canonical_lineage?(lineage) do
    case Base.url_decode64(lineage, padding: false) do
      {:ok, <<decoded::binary-size(@lineage_bytes)>>} ->
        Base.url_encode64(decoded, padding: false) == lineage

      _malformed ->
        false
    end
  end

  defp commit({:ok, value}), do: value
  defp commit({:error, reason}), do: Repo.rollback(reason)

  defp absent_row_breach(generation) do
    :telemetry.execute([:autolaunch, :session_authority, :absent_row], %{count: 1}, %{
      generation: generation
    })

    {:error, :reset}
  end

  defp claim_at(lineage, %{generation: generation}),
    do: %{lineage: lineage, generation: generation}

  defp digest(lineage), do: :crypto.hash(:sha256, lineage)
end
