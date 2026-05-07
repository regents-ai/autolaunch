defmodule Autolaunch.Privy do
  @moduledoc false

  @spec verify_token(String.t()) ::
          {:ok, %{claims: map(), privy_user_id: String.t()}} | {:error, term()}
  def verify_token(token) when is_binary(token) do
    with {:ok, app_id, verification_key} <- fetch_config(),
         signer <- Joken.Signer.create("ES256", %{"pem" => verification_key}),
         {:ok, claims} <- Joken.verify(token, signer),
         :ok <- validate_issuer(claims),
         :ok <- validate_audience(claims, app_id),
         :ok <- validate_time_claims(claims),
         {:ok, privy_user_id} <- fetch_subject(claims) do
      {:ok, %{claims: claims, privy_user_id: privy_user_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  def fetch_config do
    privy_config = Application.get_env(:autolaunch, :privy, [])
    app_id = Keyword.get(privy_config, :app_id)

    verification_key =
      privy_config
      |> Keyword.get(:verification_key)
      |> decode_pem_newlines()

    if is_binary(app_id) and app_id != "" and is_binary(verification_key) and
         verification_key != "" do
      {:ok, app_id, verification_key}
    else
      {:error, :missing_privy_config}
    end
  end

  defp decode_pem_newlines(nil), do: nil

  defp decode_pem_newlines(value) when is_binary(value) do
    value
    |> String.replace("\\r\\n", "\n")
    |> String.replace("\\n", "\n")
  end

  defp validate_issuer(%{"iss" => "privy.io"}), do: :ok
  defp validate_issuer(_claims), do: {:error, :invalid_claims}

  defp validate_audience(%{"aud" => audience}, app_id) when is_binary(audience) do
    if audience == app_id, do: :ok, else: {:error, :invalid_claims}
  end

  defp validate_audience(%{"aud" => audiences}, app_id) when is_list(audiences) do
    if app_id in audiences, do: :ok, else: {:error, :invalid_claims}
  end

  defp validate_audience(_claims, _app_id), do: {:error, :invalid_claims}

  defp validate_time_claims(claims) do
    now = System.system_time(:second)

    with {:ok, exp} <- fetch_integer_claim(claims, "exp"),
         :ok <- ensure_future(exp, now),
         :ok <- validate_not_before(claims, now),
         :ok <- validate_issued_at(claims, now) do
      :ok
    end
  end

  defp validate_not_before(claims, now) do
    case Map.fetch(claims, "nbf") do
      :error -> :ok
      {:ok, nbf} when is_integer(nbf) and nbf <= now -> :ok
      _ -> {:error, :invalid_claims}
    end
  end

  defp validate_issued_at(claims, now) do
    case Map.fetch(claims, "iat") do
      :error -> :ok
      {:ok, iat} when is_integer(iat) and iat <= now + 60 -> :ok
      _ -> {:error, :invalid_claims}
    end
  end

  defp fetch_integer_claim(claims, claim_name) do
    case Map.fetch(claims, claim_name) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, :invalid_claims}
    end
  end

  defp ensure_future(exp, now) when exp > now, do: :ok
  defp ensure_future(_exp, _now), do: {:error, :invalid_claims}

  defp fetch_subject(%{"sub" => privy_user_id})
       when is_binary(privy_user_id) and privy_user_id != "" do
    {:ok, privy_user_id}
  end

  defp fetch_subject(_claims), do: {:error, :invalid_claims}
end
