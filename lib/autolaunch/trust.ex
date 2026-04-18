defmodule Autolaunch.Trust do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.ERC8004
  alias Autolaunch.Launch
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.External.SocialAccount
  alias Autolaunch.Repo

  @x_provider "x"
  @oauth_provider "twitter"

  def x_provider, do: @x_provider
  def oauth_provider, do: @oauth_provider

  def x_accounts_by_agent_ids(agent_ids) when is_list(agent_ids) do
    normalized_ids =
      agent_ids
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    if normalized_ids == [] do
      %{}
    else
      Repo.all(
        from account in SocialAccount,
          where:
            account.agent_id in ^normalized_ids and account.provider == ^@x_provider and
              account.status == "verified" and not is_nil(account.verified_at),
          order_by: [desc: account.verified_at, desc: account.updated_at]
      )
      |> Enum.reduce(%{}, fn account, acc ->
        Map.put_new(acc, account.agent_id, account)
      end)
    end
  rescue
    _ -> %{}
  end

  def summary_for_agent(agent_id) when is_binary(agent_id) do
    identity = ERC8004.get_identities_by_agent_ids([agent_id]) |> Map.get(agent_id)
    auction = latest_agent_auction(agent_id)
    x_account = x_accounts_by_agent_ids([agent_id]) |> Map.get(agent_id)

    world_human_id = auction && auction.world_human_id
    world_connected = truthy?(auction && auction.world_registered) and present?(world_human_id)
    ens_name = live_ens_name(identity, auction)

    compose_summary(agent_id, identity, %{
      ens_name: ens_name,
      world_connected: world_connected,
      world_human_id: world_human_id,
      world_network: auction && auction.world_network,
      world_launch_count: if(world_connected, do: world_launch_count(world_human_id), else: 0),
      x_account: x_account
    })
  end

  def summary_for_agent(_agent_id), do: {:error, :invalid_agent_id}

  def compose_summary(agent_id, identity, attrs) when is_binary(agent_id) and is_map(attrs) do
    {chain_id, token_id} = parse_agent_id(agent_id)
    x_account = Map.get(attrs, :x_account)
    ens_name = Map.get(attrs, :ens_name)
    world_connected = Map.get(attrs, :world_connected, false)
    world_human_id = Map.get(attrs, :world_human_id)
    world_network = Map.get(attrs, :world_network) || "world"

    %{
      erc8004: %{
        connected: true,
        agent_id: agent_id,
        token_id: identity_value(identity, :token_id) || token_id,
        chain_id: identity_value(identity, :chain_id) || chain_id,
        registry_address:
          identity_value(identity, :registry_address) || ERC8004.identity_registry(chain_id),
        web_endpoint: identity_value(identity, :web_endpoint),
        image_url: identity_value(identity, :image_url)
      },
      ens: %{
        connected: present?(ens_name),
        name: ens_name
      },
      world: %{
        connected: world_connected,
        network: world_network,
        human_id: if(world_connected, do: world_human_id, else: nil),
        launch_count: normalize_count(Map.get(attrs, :world_launch_count, 0))
      },
      x: %{
        connected: match?(%SocialAccount{}, x_account),
        handle: x_account && x_account.handle,
        profile_url: x_account && x_account.profile_url,
        verified_at: x_account && iso(x_account.verified_at)
      }
    }
  end

  def prepare_x_link(%HumanUser{} = human, agent_id) when is_binary(agent_id) do
    with {:ok, identity} <- require_controlled_identity(human, agent_id) do
      {:ok,
       %{
         identity: identity,
         provider: @oauth_provider,
         trust_provider: @x_provider
       }}
    end
  end

  def prepare_x_link(_human, _agent_id), do: {:error, :unauthorized}

  def upsert_x_account(%HumanUser{} = human, attrs) when is_map(attrs) do
    agent_id = normalize_optional_text(Map.get(attrs, "agent_id"), 255)

    handle = normalize_handle(Map.get(attrs, "handle"))

    provider_subject =
      normalize_optional_text(Map.get(attrs, "provider_subject"), 255)

    profile_url = normalize_profile_url(Map.get(attrs, "profile_url"), handle)

    with {:ok, _identity} <- require_controlled_identity(human, agent_id),
         false <- blank?(handle),
         false <- blank?(provider_subject) do
      owner_address = primary_wallet_address(human)

      existing =
        Repo.get_by(SocialAccount,
          agent_id: agent_id,
          provider: @x_provider
        ) || %SocialAccount{}

      attrs = %{
        owner_address: owner_address,
        agent_id: agent_id,
        provider: @x_provider,
        handle: handle,
        profile_url: profile_url,
        provider_subject: provider_subject,
        status: "verified",
        verified_at: DateTime.utc_now()
      }

      existing
      |> SocialAccount.changeset(attrs)
      |> Repo.insert_or_update()
    else
      true -> {:error, :invalid_x_account}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :x_account_persist_failed}
  end

  def upsert_x_account(_human, _attrs), do: {:error, :unauthorized}

  def controls_agent?(%HumanUser{} = human, agent_id) when is_binary(agent_id) do
    match?({:ok, _identity}, require_controlled_identity(human, agent_id))
  rescue
    _ -> false
  end

  def controls_agent?(_human, _agent_id), do: false

  defp latest_agent_auction(agent_id) do
    Repo.one(
      from auction in Auction,
        where: auction.agent_id == ^agent_id,
        order_by: [desc: auction.inserted_at],
        limit: 1
    )
  rescue
    _ -> nil
  end

  defp world_launch_count(nil), do: 0
  defp world_launch_count(""), do: 0

  defp world_launch_count(human_id) do
    Repo.one(
      from auction in Auction,
        where: auction.world_registered == true and auction.world_human_id == ^human_id,
        select: count(auction.id)
    ) || 0
  rescue
    _ -> 0
  end

  defp require_controlled_identity(%HumanUser{} = human, agent_id) do
    case Launch.get_agent(human, agent_id) do
      %{agent_id: ^agent_id} = identity -> {:ok, identity}
      _ -> {:error, :agent_not_found}
    end
  end

  defp live_ens_name(%{ens: ens_name}, _auction) when is_binary(ens_name) and ens_name != "",
    do: ens_name

  defp live_ens_name(_identity, %Auction{ens_name: ens_name})
       when is_binary(ens_name) and ens_name != "",
       do: ens_name

  defp live_ens_name(_identity, _auction), do: nil

  defp identity_value(identity, key) when is_map(identity), do: Map.get(identity, key)
  defp identity_value(_identity, _key), do: nil

  defp primary_wallet_address(%HumanUser{} = human) do
    [wallet | _rest] =
      human
      |> linked_wallet_addresses()
      |> case do
        [] -> [nil]
        wallets -> wallets
      end

    wallet
  end

  defp linked_wallet_addresses(%HumanUser{} = human) do
    human.wallet_addresses
    |> List.wrap()
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_profile_url(value, handle) do
    case normalize_optional_text(value, 500) do
      nil when is_binary(handle) and handle != "" -> "https://x.com/#{handle}"
      normalized -> normalized
    end
  end

  defp normalize_handle(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 255)
    end
  end

  defp normalize_handle(_value), do: nil

  defp normalize_optional_text(value, max_length) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max_length)
    end
  end

  defp normalize_optional_text(_value, _max_length), do: nil

  defp normalize_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_address(_value), do: nil

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_value), do: 0

  defp parse_agent_id(agent_id) do
    case String.split(agent_id, ":", parts: 2) do
      [chain_id, token_id] ->
        {String.to_integer(chain_id), token_id}

      _ ->
        {launch_chain_id(), agent_id}
    end
  rescue
    _ -> {launch_chain_id(), agent_id}
  end

  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso(_value), do: nil

  defp blank?(value), do: value in [nil, ""]
  defp present?(value), do: is_binary(value) and value != ""

  defp truthy?(value), do: value in [true, "true", "1", 1, "on", "yes"]

  defp launch_chain_id do
    Application.get_env(:autolaunch, :launch, [])
    |> Keyword.get(:chain_id, 84_532)
  end
end
