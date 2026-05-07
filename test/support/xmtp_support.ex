defmodule Autolaunch.TestSupport.XmtpSupport do
  @moduledoc false

  import Plug.Conn

  alias XmtpElixirSdk.Types

  @spec setup_privy_config!() :: %{
          app_id: String.t(),
          private_pem: String.t(),
          public_pem: String.t(),
          restore: (-> any())
        }
  def setup_privy_config! do
    original_privy_cfg = Application.get_env(:autolaunch, :privy, [])
    app_id = "autolaunch-privy-test-#{unique_suffix()}"
    {private_pem, public_pem} = generate_es256_pems()

    Application.put_env(:autolaunch, :privy,
      app_id: app_id,
      verification_key: public_pem
    )

    %{
      app_id: app_id,
      private_pem: private_pem,
      public_pem: public_pem,
      restore: fn -> Application.put_env(:autolaunch, :privy, original_privy_cfg) end
    }
  end

  @spec with_privy_bearer(Plug.Conn.t(), String.t(), String.t(), String.t()) :: Plug.Conn.t()
  def with_privy_bearer(conn, privy_user_id, app_id, private_pem) do
    token = privy_bearer_token(privy_user_id, app_id, private_pem)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  @spec deterministic_inbox_id(String.t()) :: String.t()
  def deterministic_inbox_id(wallet_address) do
    identifier = %Types.Identifier{
      identifier: String.downcase(wallet_address),
      identifier_kind: :ethereum
    }

    {:ok, inbox_id} = XmtpElixirSdk.generate_inbox_id(identifier, 0, 1)
    inbox_id
  end

  @spec cast_wallet_address!(String.t()) :: String.t()
  def cast_wallet_address!(private_key) do
    {output, 0} =
      System.cmd("cast", ["wallet", "address", "--private-key", private_key],
        stderr_to_stdout: true
      )

    String.trim(output)
  end

  @spec cast_wallet_sign!(String.t(), String.t()) :: String.t()
  def cast_wallet_sign!(private_key, message) do
    {output, 0} =
      System.cmd("cast", ["wallet", "sign", "--private-key", private_key, message],
        stderr_to_stdout: true
      )

    String.trim(output)
  end

  @spec unique_suffix() :: integer()
  def unique_suffix do
    System.unique_integer([:positive, :monotonic])
  end

  defp privy_bearer_token(privy_user_id, app_id, private_pem) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "privy.io",
      "sub" => privy_user_id,
      "aud" => app_id,
      "iat" => now,
      "exp" => now + 3600
    }

    private_jwk = JOSE.JWK.from_pem(private_pem)

    {_, token} =
      private_jwk
      |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp generate_es256_pems do
    private_jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    public_jwk = JOSE.JWK.to_public(private_jwk)

    private_pem = private_jwk |> JOSE.JWK.to_pem() |> normalize_pem_output()
    public_pem = public_jwk |> JOSE.JWK.to_pem() |> normalize_pem_output()

    {private_pem, public_pem}
  end

  defp normalize_pem_output({_, pem}), do: normalize_pem_output(pem)
  defp normalize_pem_output(pem) when is_binary(pem), do: pem
  defp normalize_pem_output(pem) when is_list(pem), do: IO.iodata_to_binary(pem)
end
