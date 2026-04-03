defmodule AutolaunchWeb.PrivySessionController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Accounts
  alias Autolaunch.Portfolio
  alias Autolaunch.Privy
  alias AutolaunchWeb.ApiError

  def create(conn, params) do
    with {:ok, token} <- fetch_bearer_token(conn),
         {:ok, %{privy_user_id: privy_user_id}} <- privy_module().verify_token(token),
         {:ok, human} <- Accounts.upsert_human_by_privy_id(privy_user_id, session_attrs(params)) do
      :ok = portfolio_module().schedule_login_refresh(human)

      conn
      |> put_session(:privy_user_id, privy_user_id)
      |> json(%{
        ok: true,
        human: %{
          id: human.id,
          privy_user_id: human.privy_user_id,
          wallet_address: human.wallet_address,
          wallet_addresses: human.wallet_addresses,
          display_name: human.display_name,
          role: human.role
        }
      })
    else
      _ ->
        ApiError.render(conn, :unauthorized, "privy_required", "Valid Privy JWT required")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:privy_user_id)
    |> json(%{ok: true})
  end

  defp fetch_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case String.trim(token) do
          "" -> {:error, :invalid_authorization_header}
          normalized -> {:ok, normalized}
        end

      _ ->
        {:error, :invalid_authorization_header}
    end
  end

  defp session_attrs(params) do
    %{}
    |> maybe_put("wallet_address", Map.get(params, "wallet_address"))
    |> maybe_put(
      "wallet_addresses",
      normalize_wallet_addresses(Map.get(params, "wallet_addresses"))
    )
    |> maybe_put("display_name", Map.get(params, "display_name"))
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, _key, ""), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_wallet_addresses(values) when is_list(values) do
    values
    |> Enum.map(&normalize_wallet_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_wallet_addresses(_values), do: nil

  defp normalize_wallet_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_wallet_address(_value), do: nil

  defp portfolio_module do
    :autolaunch
    |> Application.get_env(:privy_session_controller, [])
    |> Keyword.get(:portfolio_module, Portfolio)
  end

  defp privy_module do
    :autolaunch
    |> Application.get_env(:privy_session_controller, [])
    |> Keyword.get(:privy_module, Privy)
  end
end
