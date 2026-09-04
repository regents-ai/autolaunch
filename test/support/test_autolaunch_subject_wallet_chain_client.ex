defmodule Autolaunch.TestAutolaunchSubjectWalletChainClient do
  @moduledoc """
  A fixture-bound Base client for the clean-V1 subject wallet lane.

  It is exactly what the plan permits and no more: a scripted set of bindings,
  balances, stake, claimables, allowance and per-step outcomes, so the whole
  product flow that follows a snapshot can be proved while the production client
  stays closed. It is never installed outside a test or the browser-proof server
  process, and nothing it answers is reviewed evidence.
  """

  @behaviour Autolaunch.SubjectWalletChainClient

  @key :autolaunch_subject_wallet_fixture
  @client_key :autolaunch_subject_wallet_chain_client

  @doc "Installs this fixture for the duration of the calling test, then restores what was there."
  @spec install(map()) :: :ok
  def install(fixture) do
    previous = Application.get_env(:autolaunch, @client_key)
    Application.put_env(:autolaunch, @client_key, __MODULE__)
    put(fixture)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:autolaunch, @key)
      restore(previous)
    end)
  end

  @doc "Replaces part of the scripted chain, so a later read can answer differently."
  @spec put(map()) :: :ok
  def put(changes), do: Application.put_env(:autolaunch, @key, Map.merge(state(), changes))

  @doc """
  The scripted chain this client answers from.

  An ExUnit case installs its own and has it restored afterwards. The browser
  proof's server process installs none, so it reads the one shared deterministic
  fixture — the same values every other test starts from.
  """
  @spec state() :: map()
  def state,
    do: Application.get_env(:autolaunch, @key, Autolaunch.SubjectWalletFixture.fixture())

  @impl true
  def snapshot(request) do
    case state() do
      %{unavailable: reason} -> {:error, reason}
      fixture -> {:ok, answered(fixture, request)}
    end
  end

  @impl true
  def verify(_envelope, step, hash) do
    put(%{read_in_transaction?: Autolaunch.Repo.in_transaction?()})
    raced()

    case state() |> Map.get(:outcomes, %{}) |> Map.get(step, %{outcome: :pending}) do
      {:error, reason} -> {:error, reason}
      outcome -> {:ok, Map.put_new(outcome, :hash, hash)}
    end
  end

  # The receiver is only ever read when the subject really has a projected one.
  defp answered(fixture, %{receiver: nil}), do: %{fixture.snapshot | receiver: nil}
  defp answered(fixture, _request), do: fixture.snapshot

  # Moves the operation between the read and the lease transaction, which is the
  # exact race a settlement has to survive.
  defp raced do
    case state()[:raced] do
      nil -> :ok
      move -> move.()
    end
  end

  defp restore(nil), do: Application.delete_env(:autolaunch, @client_key)
  defp restore(value), do: Application.put_env(:autolaunch, @client_key, value)
end

defmodule Autolaunch.SubjectWalletFixture do
  @moduledoc """
  The one subject wallet fixture: a launch whose splitter and canonical receiver
  agree with the pinned product bindings, an account holding the acting wallet,
  a live lease, and a scripted chain to review against.

  Every value here is fixture-bound. Nothing it produces is reviewed evidence,
  and no test that uses it may claim the production client prepares anything.
  """

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.Abi
  alias Autolaunch.TestAutolaunchSubjectWalletChainClient, as: ChainClient

  @wallet "0x1111111111111111111111111111111111111111"
  @splitter "0x2222222222222222222222222222222222222222"
  @receiver "0x3333333333333333333333333333333333333333"
  @token "0x4444444444444444444444444444444444444444"
  @treasury "0x5555555555555555555555555555555555555555"

  @unit Integer.pow(10, 18)
  @usdc_unit Integer.pow(10, 6)

  def wallet, do: @wallet
  def splitter, do: @splitter
  def receiver, do: @receiver
  def token, do: @token
  def treasury, do: @treasury
  def usdc, do: String.downcase(Abi.usdc_address())
  def regent, do: String.downcase(Abi.regent_address())

  @doc "An account holding the acting wallet, its current lease, and a stored subject."
  def actor(overrides \\ []) do
    unique = Elixir.System.unique_integer([:positive])

    account =
      Accounts.register_verified!("did:privy:subject-wallet-#{unique}", @wallet, [@wallet],
        actor: %System{}
      )

    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    human = %Human{human_account_id: account.id}

    [
      account: account,
      actor: human,
      wallet: @wallet,
      subject: subject!("subject:wallet:#{unique}", overrides),
      opts: [
        actor: human,
        context: %{session_lease: %{lineage: claim.lineage, account_id: account.id}}
      ]
    ]
  end

  @doc "A stored subject whose addresses are the ones the scripted chain answers about."
  def subject!(subject_id, overrides \\ []) do
    Autolaunch.TestSupport.project_subject(
      subject_id: subject_id,
      token_address: Keyword.get(overrides, :token_address, @token),
      splitter_address: Keyword.get(overrides, :splitter_address, @splitter),
      treasury_address: Keyword.get(overrides, :treasury_address, @treasury),
      creator_address: @wallet,
      canonical_receiver_address: Keyword.get(overrides, :canonical_receiver_address, @receiver)
    )
  end

  @doc "The scripted chain a review is derived from, with any part replaced."
  def fixture(overrides \\ []) do
    overrides = Map.new(overrides)

    # The canonical receiver names the treasury as both its beneficiary and its
    # note editor, so one treasury value drives every binding unless a test is
    # deliberately breaking one of them.
    treasury = Map.get(overrides, :treasury, @treasury)

    snapshot = %{
      splitter: %{
        subject: @token,
        usdc: usdc(),
        regent: regent(),
        treasury: treasury,
        total_staked: Map.get(overrides, :total_staked, 1_000 * @unit),
        staked_of: Map.get(overrides, :staked_of, 400 * @unit),
        claimable:
          Map.get(overrides, :claimable, %{
            subject: 0,
            usdc: 12 * @usdc_unit,
            regent: 3 * @unit
          })
      },
      receiver: %{
        splitter: @splitter,
        subject: @token,
        usdc: usdc(),
        regent: regent(),
        treasury: treasury,
        beneficiary: Map.get(overrides, :beneficiary, treasury),
        note_editor: Map.get(overrides, :note_editor, treasury),
        referral_bps: Map.get(overrides, :referral_bps, 0),
        note: Map.get(overrides, :note, note_word(@receiver)),
        balances:
          Map.get(overrides, :receiver_balances, %{
            subject: 0,
            usdc: 7 * @usdc_unit,
            regent: 0
          })
      },
      balances:
        Map.get(overrides, :balances, %{
          subject: 900 * @unit,
          usdc: 50 * @usdc_unit,
          regent: 20 * @unit
        }),
      allowance: Map.get(overrides, :allowance, 0)
    }

    %{snapshot: snapshot, outcomes: Map.get(overrides, :outcomes, %{})}
    |> Map.merge(Map.take(overrides, [:unavailable, :raced]))
  end

  @doc "Installs that scripted chain for the calling test."
  def install(overrides \\ []), do: overrides |> fixture() |> ChainClient.install()

  @doc "The receiver-address default note, exactly as the contract writes it at initialization."
  def note_word("0x" <> address),
    do: "0x" <> String.duplicate("0", 24) <> String.downcase(address)

  @doc """
  The exact refusal an action carried out, whatever its error class.

  These actions are plain boundary functions, so a typed refusal arrives bare;
  the same reason wrapped by an Ash action's error class is unwrapped too.
  """
  def refusal({:error, error}), do: refusal(error)
  def refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  def refusal(%{errors: errors}), do: Enum.find_value(errors, :unmatched, &unavailable/1)
  def refusal(reason), do: reason

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil
end
