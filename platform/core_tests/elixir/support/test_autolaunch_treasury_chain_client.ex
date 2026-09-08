defmodule Autolaunch.TestAutolaunchTreasuryChainClient do
  @behaviour Autolaunch.TreasuryChainClient

  alias Autolaunch.Actors.System
  alias Autolaunch.TreasurySecurity

  @zero "0x0000000000000000000000000000000000000000"
  @fallback "0xfd0732dc9e303f09fcef3a7388ad10a83459ec99"
  @singleton "0x41675c099f32341bf84bfc5382af534df5c7461a"
  @hash "0x" <> String.duplicate("ab", 32)
  @owners [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333"
  ]
  @browser_eoa "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

  def install(overrides \\ []) do
    Application.put_env(:autolaunch, :autolaunch_treasury_chain_client, __MODULE__)
    Application.put_env(:autolaunch, :test_autolaunch_treasury_observation, Map.new(overrides))
  end

  def seed_verified!(address, overrides \\ []) do
    install(overrides)

    {:ok, report} =
      Autolaunch.observe_treasury_security(
        address,
        %{
          usdc: "0x" <> String.duplicate("11", 32),
          regent: "0x" <> String.duplicate("22", 32),
          outbound: "0x" <> String.duplicate("33", 32)
        },
        actor: %System{}
      )

    report
  end

  @impl true
  def canonical?(_number, hash) do
    fixture = Application.get_env(:autolaunch, :test_autolaunch_treasury_observation, %{})

    canonical_hashes =
      Map.get(fixture, :canonical_hashes, [Map.get(fixture, :block_hash, @hash)])

    Map.get(fixture, :canonical?, true) and hash in canonical_hashes
  end

  @impl true
  def observe(address, hashes) do
    fixture = fixture(address)

    if reason = fixture[:error] do
      {:error, reason}
    else
      observation = %{
        block: %{
          number: Map.get(fixture, :block_number, 30_000_000),
          hash: Map.get(fixture, :block_hash, @hash)
        },
        runtime_code: Map.get(fixture, :runtime_code, "0x6001600055"),
        runtime_identity: Map.get(fixture, :runtime_identity, "0x" <> String.duplicate("44", 32)),
        admitted_safe?: Map.get(fixture, :admitted_safe?, true),
        admitted_split?: Map.get(fixture, :admitted_split?, false),
        safe_singleton: Map.get(fixture, :safe_singleton, @singleton),
        safe_version: Map.get(fixture, :safe_version, "1.4.1"),
        owners: Map.get(fixture, :owners, @owners),
        threshold: Map.get(fixture, :threshold, 2),
        modules: Map.get(fixture, :modules, []),
        guard: Map.get(fixture, :guard, @zero),
        fallback_handler: Map.get(fixture, :fallback_handler, @fallback),
        fallback_admitted?: Map.get(fixture, :fallback_admitted?, true),
        evidence: %{}
      }

      fingerprint = TreasurySecurity.fingerprint(address, observation)

      evidence =
        Map.new([:usdc, :regent, :outbound], fn key ->
          {key,
           if hashes[key] do
             %{
               verified: true,
               transaction_hash: hashes[key],
               receipt_block_number: 29_999_999,
               receipt_block_hash: "0x" <> String.duplicate("cd", 32),
               log_index: 0,
               safe_address: address,
               historical_fingerprint: fingerprint,
               decoded: Atom.to_string(key)
             }
           end}
        end)

      {:ok, %{observation | evidence: evidence}}
    end
  end

  defp fixture(@browser_eoa) do
    %{
      runtime_code: "0x",
      runtime_identity: "0x" <> String.duplicate("00", 32),
      admitted_safe?: false,
      safe_singleton: nil,
      safe_version: nil,
      owners: [],
      threshold: nil,
      fallback_admitted?: false
    }
  end

  defp fixture(_address),
    do: Application.get_env(:autolaunch, :test_autolaunch_treasury_observation, %{})
end
