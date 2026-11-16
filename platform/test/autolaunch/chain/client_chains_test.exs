defmodule Autolaunch.Chain.ClientChainsTest do
  @moduledoc """
  The networks the page gives Privy (`Autolaunch.Chain.Client.chains/0`): every
  chain the site's reviews can name, Base first, each with the public door its
  steps already give wallets and never the site's own.
  """
  use ExUnit.Case, async: false

  alias Autolaunch.Chain.Client
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @robinhood_deployment Path.expand("../../fixtures/robinhood-deployment.json", __DIR__)

  test "lists Base alone, then Base and Robinhood once the site has a Robinhood deployment, with public doors only" do
    {:ok, base} = Lab.current()
    assert Client.chains() == [Client.chain(base)]

    put_env(:autolaunch_robinhood_deployment, @robinhood_deployment)
    {:ok, robinhood} = RobinhoodLab.current()
    put_env(:autolaunch_robinhood_chain_id, robinhood.chain_id)

    assert Client.chains() == [Client.chain(base), Client.chain(robinhood)]

    assert Enum.map(Client.chains(), & &1.rpc_url) == [
             base.public_rpc_url,
             robinhood.public_rpc_url
           ]

    refute Enum.any?(Client.chains(), &(&1.rpc_url in [base.rpc_url, robinhood.rpc_url]))
  end

  defp put_env(key, value) do
    previous = Application.get_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, key, previous),
        else: Application.delete_env(:autolaunch, key)
    end)
  end
end
