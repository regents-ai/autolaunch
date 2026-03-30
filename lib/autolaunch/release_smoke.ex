defmodule Autolaunch.ReleaseSmoke do
  @moduledoc false
  import Ecto.Query, warn: false

  alias Autolaunch.Accounts
  alias Autolaunch.Launch
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Revenue

  @wallet "0x1111111111111111111111111111111111111111"
  @subject_id "0x" <> String.duplicate("1", 64)
  @splitter "0x6666666666666666666666666666666666666666"
  @ingress "0x7777777777777777777777777777777777777777"

  def run do
    ensure_mock_deploy!()

    previous_rpc = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_state = Application.get_env(:autolaunch, :release_smoke_state)
    cleanup_job_id = Process.get(:release_smoke_cleanup_job_id)

    try do
      {:ok, human} = ensure_human()
      {:ok, job} = insert_job(human)
      Process.put(:release_smoke_cleanup_job_id, job.job_id)
      :ok = Launch.process_job(job.job_id)
      job_payload = Launch.get_job_response(job.job_id, human.wallet_address)
      set_smoke_state(job_payload)
      Application.put_env(:autolaunch, :cca_rpc_adapter, __MODULE__.SmokeRpc)

      {:ok, subject} = Revenue.get_subject(@subject_id, human)
      {:ok, ingress} = Revenue.get_ingress(@subject_id, human)

      verify_job_payload(job_payload)
      verify_subject(subject)
      verify_ingress(ingress)

      %{
        ok: true,
        job_id: job.job_id,
        subject_id: @subject_id,
        checks: [
          %{
            key: "launch_job_ready",
            ok: true,
            detail: "Synthetic launch job reached ready state."
          },
          %{
            key: "trust_urls",
            ok: true,
            detail: "Launch result includes ENS and AgentBook follow-up URLs."
          },
          %{
            key: "subject_read",
            ok: true,
            detail: "Synthetic subject state loaded through the revenue context."
          },
          %{
            key: "ingress_read",
            ok: true,
            detail: "Synthetic ingress state loaded through the revenue context."
          }
        ]
      }
    after
      cleanup_smoke_artifacts(Process.get(:release_smoke_cleanup_job_id))

      if cleanup_job_id do
        Process.put(:release_smoke_cleanup_job_id, cleanup_job_id)
      else
        Process.delete(:release_smoke_cleanup_job_id)
      end

      if previous_rpc do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_rpc)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      if previous_state do
        Application.put_env(:autolaunch, :release_smoke_state, previous_state)
      else
        Application.delete_env(:autolaunch, :release_smoke_state)
      end
    end
  end

  defp ensure_mock_deploy! do
    launch = Application.get_env(:autolaunch, :launch, [])

    unless Keyword.get(launch, :mock_deploy, false) do
      raise "AUTOLAUNCH_MOCK_DEPLOY=true is required for mix autolaunch.smoke"
    end
  end

  defp ensure_human do
    Accounts.upsert_human_by_privy_id("did:privy:release-smoke", %{
      "wallet_address" => @wallet,
      "wallet_addresses" => [@wallet],
      "display_name" => "Release Smoke"
    })
  end

  defp insert_job(human) do
    now = DateTime.utc_now()
    job_id = "job_smoke_" <> Ecto.UUID.generate()
    nonce = "smoke-nonce-" <> Ecto.UUID.generate()
    signature = "smoke-signature-" <> Ecto.UUID.generate()
    message = "smoke-message-" <> Ecto.UUID.generate()

    Repo.insert(
      Job.create_changeset(%Job{}, %{
        job_id: job_id,
        privy_user_id: human.privy_user_id,
        owner_address: @wallet,
        agent_id: "11155111:42",
        agent_name: "Smoke Agent",
        token_name: "Smoke Coin",
        token_symbol: "SMOKE",
        recovery_safe_address: @wallet,
        auction_proceeds_recipient: @wallet,
        ethereum_revenue_treasury: @wallet,
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "queued",
        step: "queued",
        total_supply: "100000000000000000000000000000",
        message: message,
        siwa_nonce: nonce,
        siwa_signature: signature,
        issued_at: now,
        launch_notes: "Synthetic smoke run",
        broadcast: false,
        deploy_binary: "forge",
        deploy_workdir: File.cwd!(),
        script_target: "scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript",
        rpc_host: "mock"
      })
    )
  end

  defp verify_job_payload(%{job: job}) do
    if job.status != "ready", do: raise("Synthetic smoke job did not reach ready state.")

    if job.subject_id != @subject_id,
      do: raise("Synthetic smoke job returned the wrong subject id.")

    if job.revenue_share_splitter_address != @splitter,
      do: raise("Synthetic smoke job returned the wrong splitter.")

    if job.default_ingress_address != @ingress,
      do: raise("Synthetic smoke job returned the wrong ingress.")

    actions = job.reputation_prompt.actions || []

    ens_action = Enum.find(actions, &(&1.key == "ens"))
    world_action = Enum.find(actions, &(&1.key == "world"))

    if is_nil(ens_action) or not String.contains?(ens_action.action_url || "", "/ens-link?") do
      raise("Synthetic smoke job is missing the ENS follow-up URL.")
    end

    if is_nil(world_action) or not String.contains?(world_action.action_url || "", "/agentbook?") do
      raise("Synthetic smoke job is missing the AgentBook follow-up URL.")
    end
  end

  defp verify_subject(subject) do
    if subject.subject_id != @subject_id,
      do: raise("Synthetic subject read returned the wrong subject id.")

    if subject.splitter_address != @splitter,
      do: raise("Synthetic subject read returned the wrong splitter.")

    if subject.default_ingress_address != @ingress,
      do: raise("Synthetic subject read returned the wrong ingress.")

    if Enum.empty?(subject.ingress_accounts),
      do: raise("Synthetic subject read returned no ingress accounts.")
  end

  defp verify_ingress(ingress) do
    if ingress.subject_id != @subject_id,
      do: raise("Synthetic ingress read returned the wrong subject id.")

    if ingress.default_ingress_address != @ingress,
      do: raise("Synthetic ingress read returned the wrong ingress.")

    if Enum.empty?(ingress.accounts),
      do: raise("Synthetic ingress read returned no ingress accounts.")
  end

  defp set_smoke_state(%{job: job}) do
    Application.put_env(:autolaunch, :release_smoke_state, %{
      token_address: job.token_address,
      subject_registry_address: job.subject_registry_address
    })
  end

  defp cleanup_smoke_artifacts(nil), do: :ok

  defp cleanup_smoke_artifacts(job_id) do
    auction_id = "auc_" <> String.replace_prefix(job_id, "job_", "")
    Repo.delete_all(from auction in Auction, where: auction.source_job_id == ^auction_id)
    Repo.delete_all(from job in Job, where: job.job_id == ^job_id)
    :ok
  end

  defmodule SmokeRpc do
    @splitter "0x6666666666666666666666666666666666666666"
    @ingress "0x7777777777777777777777777777777777777777"
    @usdc "0x5555555555555555555555555555555555555555"

    def block_number(11_155_111), do: {:ok, 1}

    def eth_call(11_155_111, @splitter, data) do
      selector = String.slice(data, 0, 10)

      case selector do
        "0x817b1cd2" -> {:ok, uint(250 * Integer.pow(10, 18))}
        "0x966ed108" -> {:ok, uint(25 * Integer.pow(10, 6))}
        "0x76459dd5" -> {:ok, uint(10 * Integer.pow(10, 6))}
        "0x5f78d5f4" -> {:ok, uint(1 * Integer.pow(10, 6))}
        "0x60217267" -> {:ok, uint(12 * Integer.pow(10, 18))}
        "0xb026ee79" -> {:ok, uint(5 * Integer.pow(10, 6))}
        "0x3e413bee" -> {:ok, address(@usdc)}
        _ -> {:error, :unsupported_call}
      end
    end

    def eth_call(11_155_111, to, "0x70a08231" <> _rest) do
      cond do
        String.downcase(to) == @usdc ->
          {:ok, uint(7 * Integer.pow(10, 6))}

        String.downcase(to) == smoke_state().token_address ->
          {:ok, uint(90 * Integer.pow(10, 18))}

        true ->
          {:error, :unsupported_call}
      end
    end

    def eth_call(11_155_111, to, "0xca23dd76" <> _rest) do
      if to == ingress_factory_address(), do: {:ok, uint(1)}, else: {:error, :unsupported_call}
    end

    def eth_call(11_155_111, to, "0xb87d9995" <> _rest) do
      if to == ingress_factory_address(),
        do: {:ok, address(@ingress)},
        else: {:error, :unsupported_call}
    end

    def eth_call(11_155_111, to, "0xb396721d" <> _rest) do
      if to == ingress_factory_address(),
        do: {:ok, address(@ingress)},
        else: {:error, :unsupported_call}
    end

    def eth_call(11_155_111, subject_registry_address, "0x41c2ab07" <> _rest) do
      if subject_registry_address == smoke_state().subject_registry_address do
        {:ok, bool(true)}
      else
        {:error, :unsupported_call}
      end
    end

    def eth_call(_chain_id, _to, _data), do: {:error, :unsupported_call}

    def tx_receipt(_chain_id, _tx_hash), do: {:ok, nil}
    def tx_by_hash(_chain_id, _tx_hash), do: {:ok, nil}
    def get_logs(_chain_id, _filter), do: {:ok, []}

    defp uint(value) do
      "0x" <> (value |> Integer.to_string(16) |> String.pad_leading(64, "0"))
    end

    defp address(value) do
      "0x" <> String.pad_leading(String.slice(value, 2..-1//1), 64, "0")
    end

    defp bool(true), do: "0x" <> String.pad_leading("1", 64, "0")

    defp smoke_state do
      Application.get_env(:autolaunch, :release_smoke_state, %{})
    end

    defp ingress_factory_address do
      Application.get_env(:autolaunch, :launch, [])
      |> Keyword.get(:revenue_ingress_factory_address, "")
      |> String.downcase()
    end
  end
end
