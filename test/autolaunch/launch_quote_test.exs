defmodule Autolaunch.LaunchQuoteTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Launch
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Repo

  defmodule MissingRpcAdapter do
    def block_number(_chain_id), do: {:error, :missing_rpc_url}
    def eth_call(_chain_id, _to, _data), do: {:error, :missing_rpc_url}
    def tx_receipt(_chain_id, _tx_hash), do: {:error, :missing_rpc_url}
    def get_logs(_chain_id, _filter), do: {:error, :missing_rpc_url}
  end

  setup do
    previous_adapter = Application.get_env(:autolaunch, :cca_rpc_adapter)
    Application.put_env(:autolaunch, :cca_rpc_adapter, MissingRpcAdapter)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_adapter)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end
    end)

    auction =
      %Auction{}
      |> Auction.changeset(%{
        source_job_id: "auc_live_quote",
        agent_id: "84532:133",
        agent_name: "Regent Researcher",
        owner_address: "0x0000000000000000000000000000000000000001",
        auction_address: "0x0000000000000000000000000000000000000011",
        network: "base-sepolia",
        chain_id: 84_532,
        status: "active",
        started_at: DateTime.utc_now(),
        ends_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
        bidders: 12,
        raised_currency: "112.93 USDC",
        target_currency: "150 USDC",
        progress_percent: 75
      })
      |> Repo.insert!()

    %{auction: auction}
  end

  test "repo-backed quote exposes activity and estimator fields", %{auction: auction} do
    assert {:error, :missing_rpc_url} =
             Launch.quote_bid(auction.source_job_id, %{
               "amount" => "250.0",
               "max_price" => "0.0060"
             })
  end

  test "missing auction still returns not found" do
    assert {:error, :auction_not_found} =
             Launch.quote_bid("auc_missing", %{"amount" => "250.0", "max_price" => "0.0010"})
  end
end
