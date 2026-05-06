defmodule Autolaunch.InfrastructureConfigTest do
  use ExUnit.Case, async: false

  alias Autolaunch.InfrastructureConfig

  @root Path.expand("../..", __DIR__)

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_regent_staking = Application.get_env(:autolaunch, :regent_staking, [])
    previous_required_env = System.get_env("AUTOLAUNCH_TEST_REQUIRED_ENV")

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :regent_staking, previous_regent_staking)

      if is_nil(previous_required_env) do
        System.delete_env("AUTOLAUNCH_TEST_REQUIRED_ENV")
      else
        System.put_env("AUTOLAUNCH_TEST_REQUIRED_ENV", previous_required_env)
      end
    end)

    :ok
  end

  test "owns the supported Base chain list" do
    assert InfrastructureConfig.base_chain_ids() == [84_532, 8_453]
  end

  test "normalizes launch chain and per-chain RPC settings" do
    Application.put_env(:autolaunch, :launch,
      chain_id: "84532",
      rpc_url: "https://shared-base-sepolia.example",
      chain_rpc_urls: %{
        84_532 => " https://base-sepolia.example ",
        8_453 => "https://base.example"
      }
    )

    assert InfrastructureConfig.launch_chain_id() == {:ok, 84_532}
    assert InfrastructureConfig.rpc_url(84_532) == {:ok, "https://base-sepolia.example"}
    assert InfrastructureConfig.rpc_url(8_453) == {:ok, "https://base.example"}
  end

  test "rejects unsupported launch chains" do
    Application.put_env(:autolaunch, :launch, chain_id: 1, rpc_url: "https://eth.example")

    assert InfrastructureConfig.launch_chain_id() == {:error, :invalid_chain_id}
    assert InfrastructureConfig.rpc_url(1) == {:error, :invalid_chain_id}
  end

  test "resolves Regent staking RPC only for the configured Base chain" do
    Application.put_env(:autolaunch, :launch, chain_id: 8_453, rpc_url: "https://base.example")

    Application.put_env(:autolaunch, :regent_staking,
      chain_id: 84_532,
      rpc_url: "https://staking.example",
      contract_address: "0x1111111111111111111111111111111111111111"
    )

    assert InfrastructureConfig.rpc_url(84_532, source: :regent_staking) ==
             {:ok, "https://staking.example"}

    assert InfrastructureConfig.regent_staking_address(:contract_address) ==
             "0x1111111111111111111111111111111111111111"
  end

  test "production runtime uses pooled database URL settings" do
    runtime = File.read!(Path.join(@root, "config/runtime.exs"))

    assert runtime =~ ~s|database_url = env_required.("DATABASE_URL")|
    assert runtime =~ ~s|secret_key_base = env_required.("SECRET_KEY_BASE")|
    refute runtime =~ "DATABASE_DIRECT_URL"
    assert runtime =~ ~s|ssl: env_bool.("DATABASE_SSL", true)|
    assert runtime =~ "prepare: :unnamed"
    assert runtime =~ ~s(SET search_path TO "autolaunch",public)
    assert runtime =~ ~s|env.("ECTO_POOL_SIZE", "5")|
    assert runtime =~ ~s(migration_default_prefix: "autolaunch")
    assert runtime =~ ~s(migration_source: "schema_migrations_autolaunch")
  end

  test "required production env rejects blank values" do
    System.put_env("AUTOLAUNCH_TEST_REQUIRED_ENV", "   ")

    assert_raise RuntimeError, ~r/AUTOLAUNCH_TEST_REQUIRED_ENV is missing or blank/, fn ->
      Autolaunch.ConfigEnvLocal.fetch_required("AUTOLAUNCH_TEST_REQUIRED_ENV")
    end
  end

  test "release migrations use the direct database URL and autolaunch schema only" do
    release = File.read!(Path.join(@root, "lib/autolaunch/release.ex"))

    assert release =~ ~s|System.fetch_env!("DATABASE_DIRECT_URL")|
    refute release =~ ~s|System.fetch_env!("DATABASE_URL")|
    assert release =~ ~s(@schema "autolaunch")
    assert release =~ ~S(SET search_path TO "#{@schema}",public)
    assert release =~ ~s(@migration_source "schema_migrations_autolaunch")
    refute release =~ ~s(@schema "platform")
    refute release =~ ~s(@schema "techtree")
  end
end
