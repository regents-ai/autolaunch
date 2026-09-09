defmodule Autolaunch.TestAutolaunchBidSettlementChainClient do
  @moduledoc """
  A fixture-bound fork client for bid settlement.

  It answers `snapshot/1` with a scripted reading of the auction and the
  simulated outcome of `exitBid`/`exitPartiallyFilledBid` and `claimTokens`, so
  the exact step list and calldata a review derives from the auction's own
  answer can be proved without a fork. Nothing it answers is reviewed evidence.
  """

  @key :autolaunch_bid_settlement_fixture

  @doc "Installs this fixture for the duration of the calling test."
  @spec install(map()) :: :ok
  def install(fixture) do
    previous = Application.get_env(:autolaunch, :autolaunch_bid_settlement_chain_client)
    Application.put_env(:autolaunch, :autolaunch_bid_settlement_chain_client, __MODULE__)
    Application.put_env(:autolaunch, @key, fixture)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:autolaunch, @key)

      case previous do
        nil ->
          Application.delete_env(:autolaunch, :autolaunch_bid_settlement_chain_client)

        module ->
          Application.put_env(:autolaunch, :autolaunch_bid_settlement_chain_client, module)
      end
    end)
  end

  def snapshot(%{auction: auction, bid_id: bid_id, signer: signer}) do
    fixture = Application.get_env(:autolaunch, @key, %{})

    {:ok,
     Map.merge(fixture, %{
       auction: auction,
       signer: signer,
       bid: Map.put(fixture.bid, :id, bid_id),
       block: %{number: 100, hash: "0x" <> String.duplicate("ab", 32)},
       lab_binding: Autolaunch.Lab.binding(fake_config(), [:regent])
     })}
  end

  def verify(_envelope, _step, _hash), do: {:ok, %{outcome: :pending}}

  defp fake_config,
    do: %{
      run_id: "fixture",
      rpc_url: "http://127.0.0.1:8545",
      public_rpc_url: "http://127.0.0.1:8545",
      chain_id: 31_337,
      addresses: %{"regent" => Autolaunch.BidFixture.regent()}
    }
end
