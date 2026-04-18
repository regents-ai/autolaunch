defmodule Autolaunch.ERC8004 do
  @moduledoc false

  @agent_query """
  query Agents($where: Agent_filter, $first: Int!) {
    agents(where: $where, first: $first, orderBy: updatedAt, orderDirection: desc) {
      id
      chainId
      agentId
      owner
      operators
      agentWallet
      agentURI
      registrationFile {
        id
        name
        description
        image
        active
        ens
        webEndpoint
      }
    }
  }
  """

  @agent_ids_query """
  query AgentsById($agentIds: [String!], $first: Int!) {
    agents(where: { agentId_in: $agentIds }, first: $first, orderBy: updatedAt, orderDirection: desc) {
      id
      chainId
      agentId
      owner
      operators
      agentWallet
      agentURI
      registrationFile {
        id
        name
        description
        image
        active
        ens
        webEndpoint
      }
    }
  }
  """

  @max_results 100

  def list_accessible_identities(wallet_addresses, chain_ids \\ nil) do
    wallets =
      wallet_addresses
      |> Enum.map(&normalize_address/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if wallets == [] do
      []
    else
      resolved_chain_ids(chain_ids)
      |> Enum.flat_map(&fetch_chain_identities(&1, wallets))
      |> Enum.reduce(%{}, &merge_identity/2)
      |> Map.values()
      |> Enum.sort_by(&sort_tuple/1)
    end
  end

  def identity_registry(chain_id) do
    if chain_id == active_chain_id() do
      case Keyword.get(launch_config(), :identity_registry_address, "") do
        value when is_binary(value) and value != "" -> String.downcase(String.trim(value))
        _ -> nil
      end
    else
      nil
    end
  end

  def get_identities_by_agent_ids(agent_ids) when is_list(agent_ids) do
    agent_ids
    |> Enum.flat_map(&parse_agent_id/1)
    |> Enum.filter(fn {chain_id, _token_id} -> chain_id == active_chain_id() end)
    |> Enum.group_by(fn {chain_id, _token_id} -> chain_id end, fn {_chain_id, token_id} ->
      token_id
    end)
    |> Enum.flat_map(fn {chain_id, token_ids} ->
      fetch_public_chain_identities(chain_id, token_ids)
    end)
    |> Enum.reduce(%{}, fn identity, acc -> Map.put(acc, identity.agent_id, identity) end)
  end

  defp fetch_chain_identities(chain_id, wallets) do
    owned =
      query_agents(chain_id, %{"owner_in" => wallets})
      |> Enum.map(&decorate_identity(&1, chain_id, wallets, "owner"))

    operated =
      wallets
      |> Enum.flat_map(fn wallet ->
        query_agents(chain_id, %{"operators_contains" => [wallet]})
        |> Enum.map(&decorate_identity(&1, chain_id, wallets, "operator"))
      end)

    wallet_bound =
      wallets
      |> Enum.flat_map(fn wallet ->
        query_agents(chain_id, %{"agentWallet" => wallet})
        |> Enum.map(&decorate_identity(&1, chain_id, wallets, "wallet_bound"))
      end)

    owned ++ operated ++ wallet_bound
  end

  defp fetch_public_chain_identities(chain_id, token_ids) do
    unique_token_ids =
      token_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    with false <- unique_token_ids == [],
         {:ok, url} <- subgraph_url(chain_id),
         {:ok, response} <-
           Req.post(url,
             json: %{
               "query" => @agent_ids_query,
               "variables" => %{
                 "agentIds" => unique_token_ids,
                 "first" => length(unique_token_ids)
               }
             }
           ),
         %{"data" => %{"agents" => agents}} when is_list(agents) <- response.body do
      Enum.map(agents, &decorate_public_identity(&1, chain_id))
    else
      _ -> []
    end
  end

  defp query_agents(chain_id, where) do
    with {:ok, url} <- subgraph_url(chain_id),
         {:ok, response} <-
           Req.post(url,
             json: %{
               "query" => @agent_query,
               "variables" => %{"where" => where, "first" => @max_results}
             }
           ),
         %{"data" => %{"agents" => agents}} when is_list(agents) <- response.body do
      agents
    else
      _ -> []
    end
  end

  defp subgraph_url(chain_id) do
    launch_config = Application.get_env(:autolaunch, :launch, [])

    if chain_id == active_chain_id() do
      case Keyword.get(launch_config, :erc8004_subgraph_url, "") do
        url when is_binary(url) and url != "" -> {:ok, url}
        _ -> {:error, :missing_subgraph_url}
      end
    else
      {:error, :missing_subgraph_url}
    end
  end

  defp decorate_identity(agent, chain_id, wallets, access_mode) do
    registration = Map.get(agent, "registrationFile") || %{}
    owner = normalize_address(Map.get(agent, "owner"))
    operators = Enum.map(Map.get(agent, "operators", []), &normalize_address/1)
    agent_wallet = normalize_address(Map.get(agent, "agentWallet"))
    token_id = to_string(Map.get(agent, "agentId"))
    agent_id = "#{chain_id}:#{token_id}"

    %{
      id: agent_id,
      agent_id: agent_id,
      chain_id: chain_id,
      token_id: token_id,
      registry_address: identity_registry(chain_id),
      owner_address: owner,
      operator_addresses: operators,
      agent_wallet: agent_wallet,
      access_mode: infer_access_mode(access_mode, owner, operators, agent_wallet, wallets),
      name: Map.get(registration, "name") || "ERC-8004 Agent ##{token_id}",
      description: Map.get(registration, "description"),
      image_url: Map.get(registration, "image"),
      ens: Map.get(registration, "ens"),
      agent_uri: Map.get(agent, "agentURI"),
      web_endpoint: Map.get(registration, "webEndpoint"),
      active: truthy?(Map.get(registration, "active")),
      source: "erc8004"
    }
  end

  defp decorate_public_identity(agent, chain_id) do
    registration = Map.get(agent, "registrationFile") || %{}
    token_id = to_string(Map.get(agent, "agentId"))
    agent_id = "#{chain_id}:#{token_id}"

    %{
      id: agent_id,
      agent_id: agent_id,
      chain_id: chain_id,
      token_id: token_id,
      registry_address: identity_registry(chain_id),
      owner_address: normalize_address(Map.get(agent, "owner")),
      operator_addresses: Enum.map(Map.get(agent, "operators", []), &normalize_address/1),
      agent_wallet: normalize_address(Map.get(agent, "agentWallet")),
      name: Map.get(registration, "name") || "ERC-8004 Agent ##{token_id}",
      description: Map.get(registration, "description"),
      image_url: Map.get(registration, "image"),
      ens: Map.get(registration, "ens"),
      agent_uri: Map.get(agent, "agentURI"),
      web_endpoint: Map.get(registration, "webEndpoint"),
      active: truthy?(Map.get(registration, "active")),
      source: "erc8004"
    }
  end

  defp infer_access_mode("owner", owner, _operators, _agent_wallet, wallets) do
    if owner in wallets, do: "owner", else: "wallet_bound"
  end

  defp infer_access_mode(_access_mode, _owner, operators, _agent_wallet, wallets) do
    if Enum.any?(operators, &(&1 in wallets)), do: "operator", else: "wallet_bound"
  end

  defp merge_identity(identity, acc) do
    Map.update(acc, identity.agent_id, identity, fn existing ->
      if access_rank(identity.access_mode) < access_rank(existing.access_mode),
        do: identity,
        else: existing
    end)
  end

  defp access_rank("owner"), do: 0
  defp access_rank("operator"), do: 1
  defp access_rank("wallet_bound"), do: 2
  defp access_rank(_), do: 3

  defp sort_tuple(identity) do
    {access_rank(identity.access_mode), String.downcase(identity.name), identity.agent_id}
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp parse_agent_id(agent_id) when is_binary(agent_id) do
    case String.split(agent_id, ":", parts: 2) do
      [chain_id, token_id] ->
        with {parsed_chain_id, ""} <- Integer.parse(chain_id),
             false <- token_id == "" do
          [{parsed_chain_id, token_id}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp parse_agent_id(_agent_id), do: []

  defp normalize_address(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_address(_value), do: nil

  defp resolved_chain_ids(nil), do: [active_chain_id()]

  defp resolved_chain_ids(chain_ids) when is_list(chain_ids) do
    active = active_chain_id()

    chain_ids
    |> Enum.filter(&(&1 == active))
    |> Enum.uniq()
  end

  defp active_chain_id do
    launch_config()
    |> Keyword.get(:chain_id, 84_532)
  end

  defp launch_config, do: Application.get_env(:autolaunch, :launch, [])
end
