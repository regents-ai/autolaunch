defmodule Autolaunch.SubjectWalletNetworkTest do
  @moduledoc """
  A payment review is sent on the deployment's network, so it is built only
  when that is the token's own Base network: a deployment whose description
  names another network refuses before it reads the chain, instead of
  building a Base review for the wrong network.
  """
  use Autolaunch.DataCase, async: false

  import AutolaunchWeb.SessionAuthorityHelpers, only: [leased: 1]

  alias Autolaunch.{SubjectWalletActions, TestSupport}

  test "a deployment on another network refuses a Base subject's payment review" do
    account = TestSupport.register_creator!()

    TestSupport.project_subject(
      subject_id: "subject:network",
      chain_id: 8453,
      canonical_receiver_address: "0x9999999999999999999999999999999999999999"
    )

    # The same deployment description, naming Base Sepolia.
    description =
      Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("chain_id", 84_532)

    path =
      Path.join(System.tmp_dir!(), "subject-network-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(description))
    previous = Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)
    Application.put_env(:autolaunch, :autolaunch_base_deployment, path)

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_base_deployment, previous)
      File.rm(path)
    end)

    assert {:error, %{reason: :review_network_mismatch}} =
             SubjectWalletActions.prepare(
               "subject:network",
               account.wallet_address,
               :pay,
               %{"asset" => "usdc", "amount" => "1"},
               leased(account.id)
             )
  end
end
