defmodule AutolaunchWeb.AgentSessionController do
  use AutolaunchWeb, :controller

  import Plug.Conn

  @session_key :agent_session
  @session_ttl_seconds 1_800
  @audience "autolaunch"

  def create(conn, _params) do
    claims = conn.assigns[:current_agent_claims] || %{}
    session = build_session(claims)

    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, session)
    |> json(%{ok: true, session: session})
  end

  def show(conn, _params) do
    case current_session(conn) do
      {:ok, session} ->
        json(conn, %{ok: true, session: session})

      :expired ->
        conn
        |> delete_session(@session_key)
        |> json(%{ok: true, session: nil})

      :missing ->
        json(conn, %{ok: true, session: nil})
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(@session_key)
    |> json(%{ok: true})
  end

  defp build_session(claims) do
    now = DateTime.utc_now()
    issued_at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    expires_at =
      now
      |> DateTime.add(@session_ttl_seconds, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{
      "session_id" => Ecto.UUID.generate(),
      "audience" => @audience,
      "wallet_address" => claims["wallet_address"],
      "chain_id" => claims["chain_id"],
      "registry_address" => claims["registry_address"],
      "token_id" => claims["token_id"],
      "issued_at" => issued_at,
      "expires_at" => expires_at
    }
  end

  defp current_session(conn) do
    case get_session(conn, @session_key) do
      %{} = session ->
        with {:ok, expires_at} <- fetch_session_value(session, "expires_at"),
             {:ok, audience} <- fetch_session_value(session, "audience"),
             true <- audience == @audience,
             {:ok, parsed_expires_at, _offset} <- DateTime.from_iso8601(expires_at),
             :lt <- DateTime.compare(DateTime.utc_now(), parsed_expires_at) do
          {:ok, session}
        else
          _ -> :expired
        end

      _ ->
        :missing
    end
  end

  defp fetch_session_value(session, key) do
    case Map.get(session, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_session}
    end
  end
end
