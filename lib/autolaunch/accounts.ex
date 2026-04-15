defmodule Autolaunch.Accounts do
  @moduledoc false

  import Ecto.Query

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Repo

  def get_human_by_privy_id(nil), do: nil

  def get_human_by_privy_id(privy_user_id) when is_binary(privy_user_id) do
    Repo.get_by(HumanUser, privy_user_id: privy_user_id)
  end

  def get_human_by_wallet_address(nil), do: nil

  def get_human_by_wallet_address(wallet_address) when is_binary(wallet_address) do
    normalized_wallet = normalize_address(wallet_address)

    from(human in HumanUser,
      where:
        human.wallet_address == ^normalized_wallet or
          fragment("? = ANY(?)", ^normalized_wallet, human.wallet_addresses),
      order_by: [asc: human.id],
      limit: 1
    )
    |> Repo.one()
  end

  def upsert_human_by_privy_id(privy_user_id, attrs) do
    now = DateTime.utc_now()
    normalized_attrs = Map.put(attrs, "privy_user_id", privy_user_id)

    Repo.insert(
      HumanUser.changeset(%HumanUser{}, normalized_attrs),
      conflict_target: :privy_user_id,
      on_conflict: [set: upsert_fields(normalized_attrs, now)],
      returning: true
    )
  end

  defp upsert_fields(attrs, now) do
    attrs
    |> Enum.reduce([updated_at: now], fn {key, value}, acc ->
      case normalize_attr_key(key) do
        "wallet_address" -> [{:wallet_address, normalize_address(value)} | acc]
        "wallet_addresses" -> [{:wallet_addresses, normalize_addresses(value)} | acc]
        "display_name" -> [{:display_name, value} | acc]
        "role" -> [{:role, value} | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_attr_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_attr_key(key) when is_binary(key), do: key
  defp normalize_attr_key(_key), do: nil

  defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_address(_value), do: nil

  defp normalize_addresses(values) when is_list(values) do
    values
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_addresses(_values), do: []
end
