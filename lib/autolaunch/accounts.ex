defmodule Autolaunch.Accounts do
  @moduledoc false

  import Ecto.Query

  alias Autolaunch.Evm
  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Repo

  def get_human_by_privy_id(nil), do: nil

  def get_human_by_privy_id(privy_user_id) when is_binary(privy_user_id) do
    Repo.get_by(HumanUser, privy_user_id: privy_user_id)
  end

  def get_human_by_wallet_address(nil), do: nil

  def get_human_by_wallet_address(wallet_address) when is_binary(wallet_address) do
    case normalize_address(wallet_address) do
      nil ->
        nil

      normalized_wallet ->
        from(human in HumanUser,
          where:
            human.wallet_address == ^normalized_wallet or
              fragment("? = ANY(?)", ^normalized_wallet, human.wallet_addresses),
          order_by: [asc: human.id],
          limit: 1
        )
        |> Repo.one()
    end
  end

  def upsert_human_by_privy_id(privy_user_id, attrs) do
    now = DateTime.utc_now()
    normalized_attrs = attrs |> normalize_human_attrs() |> Map.put("privy_user_id", privy_user_id)

    Repo.insert(
      HumanUser.changeset(%HumanUser{}, normalized_attrs),
      conflict_target: :privy_user_id,
      on_conflict: [set: upsert_fields(normalized_attrs, now)],
      returning: true
    )
  end

  def open_privy_session(privy_user_id, attrs) when is_binary(privy_user_id) and is_map(attrs) do
    human = Repo.get_by(HumanUser, privy_user_id: privy_user_id) || %HumanUser{}

    attrs
    |> Map.take(["display_name"])
    |> Map.put("privy_user_id", privy_user_id)
    |> then(&HumanUser.changeset(human, &1))
    |> Repo.insert_or_update()
  end

  def update_human(%HumanUser{} = human, attrs) when is_map(attrs) do
    human
    |> HumanUser.changeset(normalize_human_attrs(attrs))
    |> Repo.update()
  end

  defp upsert_fields(attrs, now) do
    attrs
    |> Enum.reduce([updated_at: now], fn {key, value}, acc ->
      case normalize_attr_key(key) do
        "wallet_address" -> [{:wallet_address, normalize_address(value)} | acc]
        "wallet_addresses" -> [{:wallet_addresses, normalize_addresses(value)} | acc]
        "xmtp_inbox_id" -> [{:xmtp_inbox_id, normalize_text(value)} | acc]
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

  defp normalize_human_attrs(attrs) when is_map(attrs) do
    attrs
    |> maybe_put_normalized("wallet_address", normalize_address(Map.get(attrs, "wallet_address")))
    |> maybe_put_normalized(
      "wallet_addresses",
      case Map.get(attrs, "wallet_addresses") do
        values when is_list(values) -> normalize_addresses(values)
        _ -> nil
      end
    )
    |> maybe_put_normalized("xmtp_inbox_id", normalize_text(Map.get(attrs, "xmtp_inbox_id")))
  end

  defp normalize_address(value), do: Evm.normalize_address(value)

  defp normalize_addresses(values) when is_list(values) do
    values
    |> Enum.map(&Evm.normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_addresses(_values), do: []

  defp maybe_put_normalized(attrs, _key, nil), do: attrs
  defp maybe_put_normalized(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_text(value), do: Evm.normalize_string(value)
end
