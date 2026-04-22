defmodule Autolaunch.EnsLink do
  @moduledoc false

  alias AgentEns.Link
  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.ERC8004
  alias Autolaunch.Launch

  def plan_link(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, input} <- build_input(human, attrs),
         {:ok, plan} <- Link.plan(input) do
      {:ok, serialize(plan)}
    end
  end

  def plan_link(_human, _attrs), do: {:error, :unauthorized}

  def prepare_ensip25_update(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, input} <- build_input(human, attrs),
         {:ok, prepared} <- Link.prepare_ensip25_update(input) do
      {:ok, serialize(prepared)}
    end
  end

  def prepare_ensip25_update(_human, _attrs), do: {:error, :unauthorized}

  def prepare_erc8004_update(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, input} <- build_input(human, attrs),
         {:ok, prepared} <- Link.prepare_erc8004_update(input) do
      {:ok, serialize(prepared)}
    end
  end

  def prepare_erc8004_update(_human, _attrs), do: {:error, :unauthorized}

  def prepare_bidirectional_link(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, input} <- build_input(human, attrs),
         {:ok, prepared} <- Link.prepare_bidirectional_link(input) do
      {:ok, serialize(prepared)}
    end
  end

  def prepare_bidirectional_link(_human, _attrs), do: {:error, :unauthorized}

  defp build_input(%HumanUser{} = human, attrs) do
    with {:ok, identity} <- resolve_identity(human, attrs),
         {:ok, ens_name} <- required_text(Map.get(attrs, "ens_name")),
         {:ok, registry_chain_id} <- required_chain_id(identity.chain_id),
         {:ok, agent_id} <- required_numeric(identity.token_id, :agent_id),
         {:ok, ens_chain_id} <- ens_chain_id(registry_chain_id),
         {:ok, {ens_rpc_url, registry_rpc_url}} <-
           provided_or_chain_rpc_urls(attrs, ens_chain_id, registry_chain_id),
         {:ok, signer_address} <- resolve_signer_address(human, attrs) do
      {:ok,
       %{
         ens_name: ens_name,
         ens_chain_id: ens_chain_id,
         ens_rpc_url: ens_rpc_url,
         registry_chain_id: registry_chain_id,
         registry_rpc_url: registry_rpc_url,
         registry_address: identity.registry_address,
         agent_id: agent_id,
         rpc_module: Map.get(attrs, "rpc_module"),
         signer_address: signer_address,
         include_reverse?: truthy?(Map.get(attrs, "include_reverse")),
         current_agent_uri: identity.agent_uri,
         erc8004_fetcher: Map.get(attrs, "erc8004_fetcher"),
         erc8004_fetch_opts: Map.get(attrs, "erc8004_fetch_opts"),
         reverse_registrar: Map.get(attrs, "reverse_registrar")
       }}
    end
  end

  defp resolve_identity(%HumanUser{} = human, attrs) do
    identity_id = Map.get(attrs, "identity_id")

    if is_binary(identity_id) and identity_id != "" do
      case Launch.get_agent(human, identity_id) do
        nil -> {:error, :agent_not_found}
        agent -> {:ok, agent}
      end
    else
      with {:ok, chain_id} <- required_chain_id(Map.get(attrs, "chain_id")),
           {:ok, token_id} <- required_numeric(Map.get(attrs, "agent_id"), :agent_id),
           {:ok, registry_address} <- resolve_registry_address(attrs, chain_id) do
        {:ok,
         %{
           chain_id: chain_id,
           token_id: token_id,
           registry_address: registry_address,
           agent_uri: Map.get(attrs, "current_agent_uri")
         }}
      else
        nil -> {:error, :identity_registry_not_configured}
        {:error, _} = error -> error
      end
    end
  end

  defp resolve_registry_address(attrs, chain_id) do
    case normalize_address(Map.get(attrs, "registry_address")) do
      value when is_binary(value) ->
        {:ok, value}

      nil ->
        case ERC8004.identity_registry(chain_id) do
          value when is_binary(value) -> {:ok, value}
          _ -> {:error, :identity_registry_not_configured}
        end
    end
  end

  defp resolve_signer_address(%HumanUser{} = human, attrs) do
    requested = Map.get(attrs, "signer_address")
    linked_addresses = linked_wallet_addresses(human)

    signer =
      case normalize_address(requested) do
        nil -> List.first(linked_addresses)
        value -> value
      end

    if signer in linked_addresses do
      {:ok, signer}
    else
      {:error, :signer_not_linked}
    end
  end

  defp chain_rpc_url(chain_id) do
    case chain_string_config(:chain_rpc_urls, chain_id) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :rpc_not_configured}
    end
  end

  defp provided_or_chain_rpc_urls(attrs, ens_chain_id, registry_chain_id) do
    case Map.get(attrs, "rpc_url") do
      value when is_binary(value) and value != "" ->
        {:ok, {value, value}}

      _ ->
        with {:ok, ens_rpc_url} <- chain_rpc_url(ens_chain_id),
             {:ok, registry_rpc_url} <- chain_rpc_url(registry_chain_id) do
          {:ok, {ens_rpc_url, registry_rpc_url}}
        end
    end
  end

  defp required_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :ens_name_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_text(_value), do: {:error, :ens_name_required}

  defp required_numeric(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp required_numeric(value, _field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, :invalid_agent_id}
    end
  end

  defp required_numeric(_value, _field), do: {:error, :invalid_agent_id}

  defp required_chain_id(value) when is_integer(value) do
    if value in [84_532, 8_453], do: {:ok, value}, else: {:error, :invalid_chain_id}
  end

  defp required_chain_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> required_chain_id(parsed)
      _ -> {:error, :invalid_chain_id}
    end
  end

  defp required_chain_id(_value), do: {:error, :invalid_chain_id}

  defp ens_chain_id(84_532), do: {:ok, 11_155_111}
  defp ens_chain_id(8_453), do: {:ok, 1}
  defp ens_chain_id(_value), do: {:error, :invalid_chain_id}

  defp linked_wallet_addresses(%HumanUser{} = human) do
    [human.wallet_address | List.wrap(human.wallet_addresses)]
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_address(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp launch_config, do: Application.get_env(:autolaunch, :launch, [])

  defp chain_string_config(key, chain_id) do
    case Keyword.get(launch_config(), key, %{}) do
      %{} = values ->
        case Map.get(values, chain_id) do
          value when is_binary(value) and value != "" -> String.trim(value)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp serialize(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, nested} -> {key, serialize(nested)} end)
  end

  defp serialize(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} -> {key, serialize(nested)} end)
  end

  defp serialize(value) when is_list(value), do: Enum.map(value, &serialize/1)
  defp serialize(value), do: value
end
