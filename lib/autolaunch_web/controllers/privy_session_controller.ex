defmodule AutolaunchWeb.PrivySessionController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Portfolio
  alias Autolaunch.Privy
  alias AutolaunchWeb.ApiError

  def csrf(conn, _params) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> json(%{ok: true, csrf_token: token})
  end

  def create(conn, params) do
    with {:ok, wallet_address} <- normalize_required_wallet(Map.get(params, "wallet_address")),
         {:ok, wallet_addresses} <-
           normalize_wallet_addresses(Map.get(params, "wallet_addresses"), wallet_address),
         {:ok, token} <- fetch_bearer_token(conn),
         {:ok, %{privy_user_id: privy_user_id}} <- privy_module().verify_token(token),
         {:ok, human} <-
           Accounts.upsert_human_by_privy_id(privy_user_id, %{
             "wallet_address" => wallet_address,
             "wallet_addresses" => wallet_addresses,
             "display_name" => normalize_text(Map.get(params, "display_name"))
           }) do
      :ok = portfolio_module().schedule_login_refresh(human)

      conn
      |> put_session(:privy_user_id, privy_user_id)
      |> json(session_response(human))
    else
      {:error, :invalid_wallet_address} ->
        ApiError.render(
          conn,
          :bad_request,
          "invalid_wallet_address",
          "wallet_address must be a valid EVM address"
        )

      {:error, :invalid_wallet_addresses} ->
        ApiError.render(
          conn,
          :bad_request,
          "invalid_wallet_addresses",
          "wallet_addresses must include one or more valid EVM addresses"
        )

      _ ->
        ApiError.render(conn, :unauthorized, "privy_required", "Valid Privy JWT required")
    end
  end

  def show(conn, _params) do
    conn
    |> current_human()
    |> session_response()
    |> then(&json(conn, &1))
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

  defp normalize_required_wallet(value) when is_binary(value) do
    case String.trim(value) do
      <<"0x", rest::binary>> = trimmed when byte_size(rest) == 40 ->
        if String.match?(rest, ~r/\A[0-9a-fA-F]{40}\z/u) do
          {:ok, String.downcase(trimmed)}
        else
          {:error, :invalid_wallet_address}
        end

      _ ->
        {:error, :invalid_wallet_address}
    end
  end

  defp normalize_required_wallet(_value), do: {:error, :invalid_wallet_address}

  defp normalize_wallet_addresses(values, primary_wallet) when is_list(values) do
    normalized =
      values
      |> Enum.map(&normalize_wallet_value/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      normalized == [] -> {:error, :invalid_wallet_addresses}
      primary_wallet in normalized -> {:ok, normalized}
      true -> {:ok, [primary_wallet | normalized]}
    end
  end

  defp normalize_wallet_addresses(_values, _primary_wallet),
    do: {:error, :invalid_wallet_addresses}

  defp normalize_wallet_value(value) when is_binary(value) do
    case normalize_required_wallet(value) do
      {:ok, normalized} -> normalized
      _ -> nil
    end
  end

  defp normalize_wallet_value(_value), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 80)
    end
  end

  defp normalize_text(_value), do: nil

  defp current_human(conn) do
    conn
    |> get_session(:privy_user_id)
    |> Accounts.get_human_by_privy_id()
  end

  defp session_response(%HumanUser{} = human) do
    %{
      ok: true,
      human: %{
        id: human.id,
        privy_user_id: human.privy_user_id,
        wallet_address: human.wallet_address,
        wallet_addresses: human.wallet_addresses,
        display_name: human.display_name,
        role: human.role
      },
      xmtp: nil
    }
  end

  defp session_response(nil) do
    %{
      ok: true,
      human: nil,
      xmtp: nil
    }
  end
end
