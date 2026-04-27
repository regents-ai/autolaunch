defmodule AutolaunchWeb.PrivySessionController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Evm
  alias Autolaunch.Portfolio
  alias Autolaunch.Privy
  alias Autolaunch.XmtpIdentity
  alias AutolaunchWeb.ApiError

  @pending_wallet_session_key :privy_pending_wallet_address
  @pending_wallets_session_key :privy_pending_wallet_addresses

  def csrf(conn, _params) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> json(%{ok: true, csrf_token: token})
  end

  def create(conn, params) do
    with {:ok, wallet_address} <- required_wallet_address(params),
         {:ok, wallet_addresses} <- required_wallet_addresses(params, wallet_address),
         {:ok, token} <- fetch_bearer_token(conn),
         {:ok, %{privy_user_id: privy_user_id}} <- privy_module().verify_token(token),
         :ok <- ensure_existing_human_allowed(Accounts.get_human_by_privy_id(privy_user_id)),
         {:ok, human} <-
           Accounts.open_privy_session(privy_user_id, %{
             "display_name" => normalize_display_name(Map.get(params, "display_name"))
           }),
         :ok <- ensure_human_allowed(human),
         session_human = human_with_pending_wallets(human, wallet_address, wallet_addresses),
         {:ok, xmtp_result} <- XmtpIdentity.ensure_identity(session_human) do
      :ok = portfolio_module().schedule_login_refresh(session_human)

      conn
      |> write_session(privy_user_id, wallet_address, wallet_addresses)
      |> json(session_response(session_human, xmtp_result))
    else
      {:error, :human_banned} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          ok: false,
          error: %{code: "human_banned", message: "Banned humans cannot open Autolaunch sessions"}
        })

      {:error, :wallet_address_invalid} ->
        ApiError.render(
          conn,
          :bad_request,
          "invalid_wallet_address",
          "wallet_address must be a valid EVM address"
        )

      {:error, :wallet_addresses_invalid} ->
        ApiError.render(
          conn,
          :bad_request,
          "invalid_wallet_addresses",
          "wallet_addresses must include one or more valid EVM addresses"
        )

      {:error, {:missing, key}} ->
        invalid_request(conn, missing_field_code(key), missing_field_message(key))

      {:error, :wallet_address_required} ->
        invalid_request(conn, "wallet_address_required", "Connect a wallet before you continue.")

      {:error, :wallet_address_mismatch} ->
        invalid_request(
          conn,
          "wallet_address_mismatch",
          "Finish this step with the same wallet you connected."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          ok: false,
          error: %{code: "session_invalid", details: translate_changeset(changeset)}
        })

      _ ->
        ApiError.render(conn, :unauthorized, "privy_required", "Valid Privy JWT required")
    end
  end

  def complete_xmtp(conn, params) do
    with %{} = human <- current_human(conn),
         :ok <- ensure_human_allowed(human),
         {:ok, wallet_address} <- current_wallet_address(conn, human),
         {:ok, updated_human} <- XmtpIdentity.complete_identity(human, wallet_address, params),
         {:ok, persisted_human} <-
           Accounts.update_human(updated_human, %{
             "wallet_addresses" => completed_wallet_addresses(conn, wallet_address)
           }) do
      conn
      |> clear_pending_wallet_session()
      |> json(session_response(persisted_human, {:ready, persisted_human}))
    else
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          ok: false,
          error: %{
            code: "privy_session_required",
            message: "Connect your wallet before you finish room setup."
          }
        })

      {:error, :human_banned} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          ok: false,
          error: %{code: "human_banned", message: "Banned humans cannot finish room setup"}
        })

      {:error, {:missing, key}} ->
        invalid_request(conn, missing_field_code(key), missing_field_message(key))

      {:error, :wallet_address_required} ->
        invalid_request(conn, "wallet_address_required", "Connect a wallet before you continue.")

      {:error, :wallet_address_mismatch} ->
        invalid_request(
          conn,
          "wallet_address_mismatch",
          "Finish this step with the same wallet you connected."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          ok: false,
          error: %{code: "session_invalid", details: translate_changeset(changeset)}
        })

      {:error, reason} ->
        unexpected_error(conn, reason)
    end
  end

  def show(conn, _params) do
    case current_session_human(conn) do
      {conn, nil} ->
        json(conn, %{ok: true, human: nil, xmtp: nil})

      {conn, human} ->
        json(conn, session_response(human))
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_privy_session()
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

  defp required_wallet_address(params) do
    case normalize_wallet_address(Map.get(params, "wallet_address")) do
      nil -> {:error, :wallet_address_invalid}
      wallet_address -> {:ok, wallet_address}
    end
  end

  defp required_wallet_addresses(params, primary_wallet) do
    case Map.get(params, "wallet_addresses") do
      values when is_list(values) ->
        normalized =
          values
          |> Enum.map(&normalize_wallet_address/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        cond do
          normalized == [] ->
            {:error, :wallet_addresses_invalid}

          primary_wallet in normalized ->
            {:ok, normalized}

          true ->
            {:ok, [primary_wallet | normalized]}
        end

      _ ->
        {:error, :wallet_addresses_invalid}
    end
  end

  defp normalize_wallet_address(value), do: Evm.normalize_address(value)

  defp normalize_display_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 80)
    end
  end

  defp normalize_display_name(_value), do: nil

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

  defp current_human(conn) do
    conn
    |> get_session(:privy_user_id)
    |> Accounts.get_human_by_privy_id()
  end

  defp current_session_human(conn) do
    case current_human(conn) do
      %{role: "banned"} ->
        {clear_privy_session(conn), nil}

      %{} = human ->
        pending_wallet = pending_wallet_address(conn)
        pending_wallets = pending_wallet_addresses(conn)
        {conn, human_with_pending_wallets(human, pending_wallet, pending_wallets)}

      nil ->
        {conn, nil}
    end
  end

  defp pending_wallet_address(conn) do
    conn
    |> get_session(@pending_wallet_session_key)
    |> normalize_wallet_address()
  end

  defp pending_wallet_addresses(conn) do
    case get_session(conn, @pending_wallets_session_key) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_wallet_address/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp current_wallet_address(conn, human) do
    case pending_wallet_address(conn) || human.wallet_address do
      nil -> {:error, :wallet_address_required}
      wallet_address -> {:ok, wallet_address}
    end
  end

  defp completed_wallet_addresses(conn, wallet_address) do
    case pending_wallet_addresses(conn) do
      [] ->
        [wallet_address]

      values ->
        if Enum.member?(values, wallet_address), do: values, else: [wallet_address | values]
    end
  end

  defp human_with_pending_wallets(%HumanUser{} = human, nil, _pending_wallets), do: human

  defp human_with_pending_wallets(%HumanUser{} = human, pending_wallet, pending_wallets) do
    pending_wallets =
      case pending_wallets do
        [] ->
          [pending_wallet]

        values ->
          if Enum.member?(values, pending_wallet), do: values, else: [pending_wallet | values]
      end

    %{human | wallet_address: pending_wallet, wallet_addresses: pending_wallets}
  end

  defp ensure_human_allowed(%{role: "banned"}), do: {:error, :human_banned}
  defp ensure_human_allowed(_human), do: :ok

  defp ensure_existing_human_allowed(%{role: "banned"}), do: {:error, :human_banned}
  defp ensure_existing_human_allowed(_human), do: :ok

  defp write_session(conn, privy_user_id, wallet_address, wallet_addresses) do
    conn
    |> put_session(:privy_user_id, privy_user_id)
    |> put_session(@pending_wallet_session_key, wallet_address)
    |> put_session(@pending_wallets_session_key, wallet_addresses)
  end

  defp clear_privy_session(conn) do
    conn
    |> delete_session(:privy_user_id)
    |> delete_session("privy_user_id")
    |> clear_pending_wallet_session()
  end

  defp clear_pending_wallet_session(conn) do
    conn
    |> delete_session(@pending_wallet_session_key)
    |> delete_session(Atom.to_string(@pending_wallet_session_key))
    |> delete_session(@pending_wallets_session_key)
    |> delete_session(Atom.to_string(@pending_wallets_session_key))
  end

  defp session_response(%HumanUser{} = human, xmtp_result \\ nil) do
    {resolved_human, xmtp_state} = resolve_session_state(human, xmtp_result)

    %{
      ok: true,
      human: %{
        id: resolved_human.id,
        privy_user_id: resolved_human.privy_user_id,
        wallet_address: resolved_human.wallet_address,
        wallet_addresses: resolved_human.wallet_addresses,
        display_name: resolved_human.display_name,
        role: resolved_human.role,
        xmtp_inbox_id: response_inbox_id(resolved_human, xmtp_state)
      },
      xmtp: xmtp_state
    }
  end

  defp resolve_session_state(human, nil), do: {human, xmtp_state(human)}

  defp resolve_session_state(_human, {:ready, updated_human}),
    do: {updated_human, ready_xmtp_state(updated_human)}

  defp resolve_session_state(_human, {:signature_required, updated_human, attrs}) do
    {updated_human, signature_required_xmtp_state(updated_human, attrs)}
  end

  defp resolve_session_state(human, _result), do: {human, xmtp_state(human)}

  defp xmtp_state(human) do
    case XmtpIdentity.ready_inbox_id(human) do
      {:ok, _inbox_id} -> ready_xmtp_state(human)
      {:error, _reason} -> nil
    end
  end

  defp ready_xmtp_state(human) do
    {:ok, inbox_id} = XmtpIdentity.ready_inbox_id(human)

    %{
      status: "ready",
      inbox_id: inbox_id,
      wallet_address: human.wallet_address
    }
  end

  defp signature_required_xmtp_state(human, attrs) do
    %{
      status: "signature_required",
      inbox_id: nil,
      wallet_address: human.wallet_address,
      client_id: Map.get(attrs, :client_id) || Map.get(attrs, "client_id"),
      signature_request_id:
        Map.get(attrs, :signature_request_id) || Map.get(attrs, "signature_request_id"),
      signature_text: Map.get(attrs, :signature_text) || Map.get(attrs, "signature_text")
    }
  end

  defp response_inbox_id(_human, xmtp_state) do
    case xmtp_state do
      %{"status" => "ready", "inbox_id" => inbox_id} -> inbox_id
      %{status: "ready", inbox_id: inbox_id} -> inbox_id
      _ -> nil
    end
  end

  defp invalid_request(conn, code, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, error: %{code: code, message: message}})
  end

  defp unexpected_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      ok: false,
      error: %{code: "xmtp_setup_failed", message: inspect(reason)}
    })
  end

  defp missing_field_code(key), do: "#{key}_required"
  defp missing_field_message(key), do: "#{key} is required"

  defp translate_changeset(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
