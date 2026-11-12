defmodule Autolaunch.ThirdLaunchers do
  @moduledoc """
  The tests' two Base descriptions as the ceremony writes them once Base's
  third Revstake factory and Memestock launchpad are deployed: the second
  launchers' own contracts move into `v2` sections, and stand-ins for the
  third take the top level. The third launchpad's ABI is its own
  (`contracts/abi/stocks-launchpad-v3.json`); the third Revstake contracts
  declare the second's signatures, so their ABIs stay as they are.
  `install/1` points the site at them for one test.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @revstake_own ~w(factory hook lp_locker strategy)
  @stocks_own ~w(bid_adapter hook launchpad locker)
  @stocks_own_abis ~w(hook launchpad locker)

  @revstake %{
    "factory" => "0x3000000000000000000000000000000000000001",
    "hook" => "0x3000000000000000000000000000000000000002",
    "lp_locker" => "0x3000000000000000000000000000000000000003",
    "strategy" => "0x3000000000000000000000000000000000000004"
  }

  @stocks %{
    "launchpad" => "0x3000000000000000000000000000000000000011",
    "hook" => "0x3000000000000000000000000000000000000012",
    "locker" => "0x3000000000000000000000000000000000000013",
    "bid_adapter" => "0x3000000000000000000000000000000000000014"
  }

  @doc "The stand-in third Revstake factory, strategy, hook and LP locker, by description key."
  def revstake, do: @revstake

  @doc "The stand-in third Memestock launchpad, hook, locker and bid adapter, by description key."
  def stocks, do: @stocks

  @doc "Writes both descriptions into `dir` and points the site at them until the test ends."
  def install(dir) do
    place(:autolaunch_base_deployment, Path.join(dir, "base-v3.json"), &third_revstake/1)

    place(
      :autolaunch_base_stocks_deployment,
      Path.join(dir, "base-stocks-v3.json"),
      &third_stocks/1
    )
  end

  defp place(key, path, third) do
    previous = Application.fetch_env!(:autolaunch, key)
    File.write!(path, previous |> File.read!() |> Jason.decode!() |> third.() |> Jason.encode!())
    Application.put_env(:autolaunch, key, path)
    on_exit(fn -> Application.put_env(:autolaunch, key, previous) end)
  end

  defp third_revstake(description) do
    description
    |> Map.put("v2", own(description, @revstake_own, @revstake_own))
    |> Map.update!("addresses", &Map.merge(&1, @revstake))
  end

  # The Stocks description names the Revstake factory it shares a site with.
  defp third_stocks(description) do
    description
    |> Map.put("v2", own(description, @stocks_own, @stocks_own_abis))
    |> Map.update!(
      "addresses",
      &Map.merge(&1, Map.put(@stocks, "agent_factory", @revstake["factory"]))
    )
    |> Map.update!("abis", &Map.put(&1, "launchpad", launchpad_abi()))
  end

  defp own(description, address_keys, abi_keys),
    do: %{
      "addresses" => Map.take(description["addresses"], address_keys),
      "abis" => Map.take(description["abis"], abi_keys)
    }

  defp launchpad_abi,
    do:
      Path.expand("../../contracts/abi/stocks-launchpad-v3.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
end
