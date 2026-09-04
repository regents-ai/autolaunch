defmodule Autolaunch.TestAutolaunchBidChainClient do
  @moduledoc """
  A fixture-bound Base client for the Autolaunch bidder.

  It is exactly what the plan permits and no more: an exact predecessor tick and
  a scripted allowance, balance and per-step outcome, so the product flow that
  follows a snapshot can be proved while the production client stays closed. It
  is never installed outside a test, and nothing it answers is reviewed evidence.
  """

  @behaviour Autolaunch.ChainClient

  @key :autolaunch_bid_fixture

  @doc "Installs this fixture for the duration of the calling test."
  @spec install(map()) :: :ok
  def install(fixture) do
    previous_client = Application.get_env(:autolaunch, :autolaunch_bid_chain_client)
    Application.put_env(:autolaunch, :autolaunch_bid_chain_client, __MODULE__)
    put(fixture)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:autolaunch, @key)
      restore(:autolaunch_bid_chain_client, previous_client)
    end)
  end

  @doc "Replaces part of the scripted chain, so a later read can answer differently."
  @spec put(map()) :: :ok
  def put(changes),
    do: Application.put_env(:autolaunch, @key, Map.merge(state(), changes))

  @spec state() :: map()
  def state, do: Application.get_env(:autolaunch, @key, %{})

  @impl true
  def snapshot(%{max_price_q96: max_price_q96}) do
    case state() do
      %{unavailable: reason} ->
        {:error, reason}

      fixture ->
        {:ok,
         %{
           currency: fixture.currency,
           regent_balance: fixture.regent_balance,
           token_allowance: fixture.token_allowance,
           permit2_amount: fixture.permit2_amount,
           permit2_expiration: fixture.permit2_expiration,
           predecessor_source: fixture.predecessor_source,
           prev_tick_price_q96: predecessor(max_price_q96, fixture)
         }}
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

  # No predecessor is asked for by the wallet position read, and none is invented.
  defp predecessor(nil, _fixture), do: nil
  defp predecessor(_max_price_q96, fixture), do: fixture.prev_tick_price_q96

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end

defmodule Autolaunch.BidFixture do
  @moduledoc """
  The one bidder fixture: an account holding a wallet, a live lease, an auction
  raising the bound REGENT, and a scripted chain to review against.

  Every value here is fixture-bound. Nothing it produces is reviewed evidence,
  and no test that uses it may claim the production client prepares anything.
  """

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.Abi
  alias Autolaunch.TestAutolaunchBidChainClient

  @wallet "0x1111111111111111111111111111111111111111"
  @auction_address "0x3333333333333333333333333333333333333333"
  @q96 79_228_162_514_264_337_593_543_950_336

  def wallet, do: @wallet
  def auction_address, do: @auction_address
  def regent, do: String.downcase(Abi.regent_address())
  def system, do: %System{}

  @doc "An account holding the bidder wallet, its current lease, and a live auction."
  def bidder(_context \\ %{}) do
    unique = Elixir.System.unique_integer([:positive])

    account =
      Accounts.register_verified!("did:privy:bidder-#{unique}", @wallet, [@wallet],
        actor: %System{}
      )

    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    actor = %Human{human_account_id: account.id}

    {:ok,
     account: account,
     actor: actor,
     wallet: @wallet,
     regent: regent(),
     auction: auction!("Bidder auction #{unique}"),
     opts: [
       actor: actor,
       context: %{session_lease: %{lineage: claim.lineage, account_id: account.id}}
     ]}
  end

  @doc "A live auction whose stored terms name the bound REGENT."
  def auction!(title) do
    Autolaunch.TestSupport.project_auction(
      title: title,
      featured: false,
      state: :active,
      opened_at: ~U[2026-08-20 11:00:00Z]
    )
    |> Autolaunch.set_auction_bid_terms!(@auction_address, regent(), "REGENT", 18, "2.5",
      actor: %System{}
    )
  end

  @doc "The scripted chain a review is derived from, with any part replaced."
  def fixture(overrides \\ []) do
    %{
      currency: regent(),
      regent_balance: 100 * Integer.pow(10, 18),
      token_allowance: 0,
      permit2_amount: 0,
      permit2_expiration: 0,
      predecessor_source: "fixture",
      prev_tick_price_q96: 2 * @q96,
      outcomes: %{}
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc "Installs that scripted chain for the calling test."
  def install(overrides \\ []),
    do: overrides |> fixture() |> TestAutolaunchBidChainClient.install()

  @doc "The exact refusal an Ash action carried out, whatever its error class."
  def refusal(%{errors: errors}), do: Enum.find_value(errors, :unmatched, &unavailable/1)
  def refusal(reason), do: reason

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil
end
