defmodule AutolaunchWeb.WalletChainsTest do
  @moduledoc """
  The networks the page gives Privy, in the head's `wallet-chains` from
  `Autolaunch.Chain.Client.chains/0`: every chain the site's reviews can name,
  Base first or none at all, each with the public door its steps already give
  wallets and never the site's own.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Chain.Client
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @robinhood_deployment Path.expand("../fixtures/robinhood-deployment.json", __DIR__)

  test "lists Base alone, then Base and Robinhood once the site has a Robinhood deployment, with public doors only" do
    {:ok, base} = Lab.current()
    assert Client.chains() == [Client.chain(base)]

    robinhood = put_robinhood()

    assert Client.chains() == [Client.chain(base), Client.chain(robinhood)]

    assert Enum.map(Client.chains(), & &1.rpc_url) == [
             base.public_rpc_url,
             robinhood.public_rpc_url
           ]
  end

  test "a site without a Base deployment has no wallet chain, even with a Robinhood one" do
    put_robinhood()
    put_env(:autolaunch_base_deployment, nil)

    assert {:error, :deployment_missing} = Lab.current()
    assert Client.chains() == []
  end

  test "the page carries each wallet chain's public door and never the site's own", %{conn: conn} do
    robinhood = put_robinhood()
    {:ok, base} = Lab.current()

    html = conn |> put_req_header("accept", "text/html") |> get("/about") |> html_response(200)

    [content] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("meta[name='wallet-chains']")
      |> LazyHTML.attribute("content")

    assert content |> Jason.decode!() |> Enum.map(& &1["rpc_url"]) ==
             [base.public_rpc_url, robinhood.public_rpc_url]

    for config <- [base, robinhood] do
      assert config.rpc_url != config.public_rpc_url
      refute html =~ config.rpc_url
    end
  end

  defp put_robinhood do
    put_env(:autolaunch_robinhood_deployment, @robinhood_deployment)
    {:ok, robinhood} = RobinhoodLab.current()
    put_env(:autolaunch_robinhood_chain_id, robinhood.chain_id)
    robinhood
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
