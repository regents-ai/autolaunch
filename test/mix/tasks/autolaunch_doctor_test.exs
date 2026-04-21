defmodule Mix.Tasks.Autolaunch.DoctorTest do
  use Autolaunch.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_privy = Application.get_env(:autolaunch, :privy, [])
    previous_siwa = Application.get_env(:autolaunch, :siwa, [])
    previous_networks = Application.get_env(:agent_world, :networks, %{})
    previous_rpc = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_http = Application.get_env(:autolaunch, :release_doctor_http_client)

    tempdir =
      Path.join(System.tmp_dir!(), "autolaunch-doctor-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tempdir)

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch,
        deploy_binary: "zsh",
        deploy_workdir: tempdir,
        deploy_script_target:
          "scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript",
        cca_factory_address: "0x1111111111111111111111111111111111111111",
        pool_manager_address: "0x2222222222222222222222222222222222222222",
        position_manager_address: "0x3333333333333333333333333333333333333333",
        usdc_address: "0x4444444444444444444444444444444444444444",
        pool_manager_addresses: %{
          84_532 => "0x2222222222222222222222222222222222222222",
          8_453 => "0x1212121212121212121212121212121212121212"
        },
        usdc_addresses: %{
          84_532 => "0x4444444444444444444444444444444444444444",
          8_453 => "0x1313131313131313131313131313131313131313"
        },
        identity_registry_address: "0x9999999999999999999999999999999999999998",
        revenue_share_factory_address: "0x5555555555555555555555555555555555555555",
        revenue_ingress_factory_address: "0x6666666666666666666666666666666666666666",
        revenue_share_factory_addresses: %{
          84_532 => "0x5555555555555555555555555555555555555555",
          8_453 => "0x1414141414141414141414141414141414141414"
        },
        revenue_ingress_factory_addresses: %{
          84_532 => "0x6666666666666666666666666666666666666666",
          8_453 => "0x1515151515151515151515151515151515151515"
        },
        lbp_strategy_factory_address: "0x7777777777777777777777777777777777777777",
        token_factory_address: "0x8888888888888888888888888888888888888888"
      )
    )

    Application.put_env(:autolaunch, :privy, app_id: "test-app", verification_key: "test-key")

    Application.put_env(:autolaunch, :siwa, internal_url: "http://siwa.test")

    Application.put_env(:autolaunch, :cca_rpc_adapter, Mix.Tasks.Autolaunch.DoctorTest.DoctorRpc)

    Application.put_env(
      :autolaunch,
      :release_doctor_http_client,
      Mix.Tasks.Autolaunch.DoctorTest.DoctorHttp
    )

    Application.put_env(:agent_world, :networks, %{
      "world" => %{
        rpc_url: "https://world.example",
        contract_address: "0x9999999999999999999999999999999999999999"
      },
      "base" => %{
        rpc_url: "https://base.example",
        contract_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      "base-sepolia" => %{
        rpc_url: "https://base-sepolia.example",
        contract_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      }
    })

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :privy, previous_privy)
      Application.put_env(:autolaunch, :siwa, previous_siwa)
      Application.put_env(:agent_world, :networks, previous_networks)

      if previous_rpc do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_rpc)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      if previous_http do
        Application.put_env(:autolaunch, :release_doctor_http_client, previous_http)
      else
        Application.delete_env(:autolaunch, :release_doctor_http_client)
      end
    end)

    Mix.Task.reenable("autolaunch.doctor")
    :ok
  end

  test "doctor task prints a success footer" do
    output =
      capture_io(fn ->
        Mix.Tasks.Autolaunch.Doctor.run([])
      end)

    assert output =~ "Autolaunch doctor passed."
  end

  defmodule DoctorRpc do
    def block_number(84_532), do: {:ok, 321}
    def eth_call(_chain_id, _to, _data), do: {:error, :unsupported}
    def tx_receipt(_chain_id, _tx_hash), do: {:ok, nil}
    def tx_by_hash(_chain_id, _tx_hash), do: {:ok, nil}
    def get_logs(_chain_id, _filter), do: {:ok, []}
  end

  defmodule DoctorHttp do
    def get(_opts), do: {:ok, %{status: 204}}
  end
end
