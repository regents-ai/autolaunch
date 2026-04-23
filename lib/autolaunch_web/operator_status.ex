defmodule AutolaunchWeb.OperatorStatus do
  @moduledoc false

  alias Autolaunch.Dragonfly
  alias Autolaunch.Repo
  alias Autolaunch.Siwa.Config, as: SiwaConfig

  def snapshot do
    checks = [
      repo_check(),
      dragonfly_check(),
      siwa_check(),
      launch_config_check(),
      regent_config_check(),
      xmtp_config_check()
    ]

    %{
      ok: Enum.all?(checks, &(&1.state == :ready)),
      checked_at: DateTime.utc_now(),
      checks: checks
    }
  end

  defp repo_check do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> check(:ready, "Database", "Reads and writes are available.")
      {:error, _reason} -> check(:blocked, "Database", "Database is not accepting queries.")
    end
  end

  defp dragonfly_check do
    case Dragonfly.status() do
      :ready -> check(:ready, "Dragonfly", "Hot read cache is ready.")
      :disabled -> check(:muted, "Dragonfly", "Cache is disabled in this environment.")
      {:error, _reason} -> check(:blocked, "Dragonfly", "Cache is not reachable.")
    end
  end

  defp siwa_check do
    case SiwaConfig.fetch_http_config() do
      {:ok, %{internal_url: _url}} -> check(:ready, "Agent sign-in", "Agent auth is configured.")
      {:error, _reason} -> check(:blocked, "Agent sign-in", "Agent auth needs configuration.")
    end
  end

  defp launch_config_check do
    launch = Application.get_env(:autolaunch, :launch, [])

    required = [
      :chain_id,
      :cca_factory_address,
      :pool_manager_address,
      :position_manager_address,
      :usdc_address,
      :revenue_share_factory_address,
      :revenue_ingress_factory_address,
      :lbp_strategy_factory_address,
      :token_factory_address,
      :identity_registry_address
    ]

    missing =
      Enum.reject(required, fn key ->
        launch
        |> Keyword.get(key)
        |> present?()
      end)

    if missing == [] do
      check(:ready, "Launch stack", "Base launch addresses are configured.")
    else
      check(:blocked, "Launch stack", "#{length(missing)} launch settings need values.")
    end
  end

  defp regent_config_check do
    cfg = Application.get_env(:autolaunch, :regent_staking, [])

    if present?(Keyword.get(cfg, :contract_address)) and present?(Keyword.get(cfg, :rpc_url)) do
      check(:ready, "Regent staking", "Regent staking reads are configured.")
    else
      check(:muted, "Regent staking", "Regent staking is not fully configured here.")
    end
  end

  defp xmtp_config_check do
    rooms =
      :autolaunch
      |> Application.get_env(Autolaunch.Xmtp, [])
      |> Keyword.get(:rooms, [])

    if is_list(rooms) and rooms != [] do
      check(:ready, "XMTP rooms", "#{length(rooms)} room setup is configured.")
    else
      check(:blocked, "XMTP rooms", "No XMTP room setup is configured.")
    end
  end

  defp check(state, label, detail), do: %{state: state, label: label, detail: detail}

  defp present?(value) when is_integer(value), do: true
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
