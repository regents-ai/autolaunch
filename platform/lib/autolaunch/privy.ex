defmodule Autolaunch.Privy do
  @moduledoc """
  Exchanges a Privy access and identity token pair for the verified session
  every Regent site shares, checked against the same configured public keys.
  """

  @type session_pair :: %{access: String.t(), identity: String.t()}
  @type stage :: :configuration | :access_verification | :identity_verification | :pair_binding
  @type rejection :: {stage(), atom()}

  @callback verify_session_pair(session_pair()) ::
              {:ok, RegentPrivy.Session.t()} | {:error, rejection()}

  @doc """
  Verifies the pair. A refusal names the boundary that refused it as
  `{stage, reason}`, drawn only from the shared verifier's fixed vocabulary.
  """
  def verify_session_pair(pair), do: RegentPrivy.Session.verify(pair, privy_config())

  def app_id, do: privy_config()[:app_id]

  defp privy_config, do: Application.get_env(:autolaunch, :privy, [])
end
