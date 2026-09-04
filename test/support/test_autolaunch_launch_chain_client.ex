defmodule Autolaunch.TestAutolaunchLaunchChainClient do
  @moduledoc """
  A fixture-bound Base client for the direct-wallet launch lane.

  It is exactly what the plan permits and no more: a scripted factory identity,
  fee, pause state, balance, allowance, reciprocal strategy binding, bound fee
  hook, founder-frozen terms and per-step outcomes, so the whole product flow
  that follows a snapshot can be proved while the production client stays
  closed. It is never installed outside a test or the browser-proof server
  process, and nothing it answers is reviewed evidence.
  """

  @behaviour Autolaunch.LaunchChainClient

  @key :autolaunch_launch_fixture
  @client_key :autolaunch_launch_chain_client

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
  def state, do: Application.get_env(:autolaunch, @key, Autolaunch.LaunchFixture.fixture())

  @impl true
  def snapshot(_request) do
    put(%{snapshot_read_in_transaction?: Autolaunch.Repo.in_transaction?()})
    raced()

    case state() do
      %{unavailable: reason} -> {:error, reason}
      fixture -> {:ok, fixture.snapshot}
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

defmodule Autolaunch.LaunchFixture do
  @moduledoc """
  The one direct-wallet launch fixture: a factory reciprocally bound to its own
  strategy, an account holding the acting wallet, one account-owned saved
  launch draft with its immutable image, a live lease, and a scripted chain to
  review against.

  Every value here is fixture-bound. Nothing it produces is reviewed evidence,
  and no test that uses it may claim the production client prepares anything.
  """

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.Abi
  alias Autolaunch.LaunchDraftImageStorage
  alias Autolaunch.TestAutolaunchLaunchChainClient, as: ChainClient

  @wallet "0x1111111111111111111111111111111111111111"
  @factory "0x7777777777777777777777777777777777777777"
  @strategy "0x8888888888888888888888888888888888888888"
  @treasury "0x5555555555555555555555555555555555555555"
  @hook "0x6666666666666666666666666666666666666666"

  @unit Integer.pow(10, 18)

  # The founder-frozen launch terms, transcribed from the integrated strategy.
  @terms %{
    start_delay_blocks: 1_800,
    auction_duration_blocks: 86_401,
    claim_delay_blocks: 64,
    migration_delay_blocks: 128,
    floor_price_q96: 79_228_162_514_264_337_593_543_900,
    bid_tick_q96: 792_281_625_142_643_375_935_439,
    auction_allocation: 10_000_000_000 * @unit,
    reserve_allocation: 5_000_000_000 * @unit,
    pending_allocation: 85_000_000_000 * @unit,
    pool_fee: 3_000,
    pool_tick_spacing: 60,
    max_reachable_raise: 658_201_822_928_399_999_999_999_581_824_872_526
  }

  @draft %{
    "name" => "Open Research",
    "symbol" => "OPEN",
    "description" => "A launch profile awaiting review.",
    "website" => "https://example.test/open",
    "treasury" => @treasury,
    "required_regent_raised" => "1000.5"
  }

  def wallet, do: @wallet
  def factory, do: @factory
  def strategy, do: @strategy
  def treasury, do: @treasury
  def hook, do: @hook
  def terms, do: @terms

  @doc "An account holding the acting wallet, its lease, and one saved account-owned draft."
  def actor(overrides \\ []) do
    unique = Elixir.System.unique_integer([:positive])

    account =
      Accounts.register_verified!("did:privy:launch-#{unique}", @wallet, [@wallet],
        actor: %System{}
      )

    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    human = %Human{human_account_id: account.id}

    [
      account: account,
      actor: human,
      wallet: @wallet,
      draft: draft!(human, overrides),
      opts: [
        actor: human,
        context: %{session_lease: %{lineage: claim.lineage, account_id: account.id}}
      ]
    ]
  end

  @doc "One saved clean-V1 draft owned by `actor`, with any field replaced."
  def draft!(actor, overrides \\ []) do
    draft =
      @draft
      |> Map.merge(Map.new(Keyword.get(overrides, :draft, %{})))
      |> Map.delete("image")
      |> Autolaunch.create_launch_draft!(actor: actor)

    case Autolaunch.get_my_launch_draft_image(draft.id, actor: actor) do
      {:ok, nil} ->
        {:ok, %{draft: attached}} =
          LaunchDraftImageStorage.store_and_attach(
            draft,
            launch_image(),
            "image/png",
            "launch.png",
            actor
          )

        attached

      {:ok, _existing_image} ->
        draft
    end
  end

  @doc "The scripted chain a review is derived from, with any part replaced."
  def fixture(overrides \\ []) do
    overrides = Map.new(overrides)

    snapshot = %{
      factory: Map.get(overrides, :factory, @factory),
      strategy: Map.get(overrides, :strategy, @strategy),
      strategy_factory: Map.get(overrides, :strategy_factory, @factory),
      fee: Map.get(overrides, :fee, 1_000_000 * @unit),
      paused: Map.get(overrides, :paused, false),
      balance: Map.get(overrides, :balance, 5_000_000 * @unit),
      allowance: Map.get(overrides, :allowance, 0),
      hook: Map.get(overrides, :hook, @hook),
      terms: Map.merge(@terms, Map.get(overrides, :terms, %{})),
      block: Map.get(overrides, :block, %{number: 30_000_000, hash: block_hash()}),
      regent: Map.get(overrides, :regent, Abi.regent_address())
    }

    %{snapshot: snapshot, outcomes: Map.get(overrides, :outcomes, %{})}
    |> Map.merge(Map.take(overrides, [:unavailable, :raced]))
  end

  @doc "Installs that scripted chain for the calling test."
  def install(overrides \\ []), do: overrides |> fixture() |> ChainClient.install()

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

  defp block_hash, do: "0x" <> String.duplicate("ab", 32)

  defp launch_image do
    File.read!("test/support/fixtures/launch-draft.png")
  end
end
