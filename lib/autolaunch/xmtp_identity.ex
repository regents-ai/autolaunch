defmodule Autolaunch.XmtpIdentity do
  @moduledoc false

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanUser
  alias Xmtp.Identity

  @runtime_name __MODULE__.Runtime

  @type ensure_result ::
          {:ready, HumanUser.t()}
          | {:signature_required, HumanUser.t(), map()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Identity.child_spec(Keyword.put_new(opts, :name, @runtime_name))
  end

  @spec ensure_identity(HumanUser.t()) :: {:ok, ensure_result()} | {:error, term()}
  def ensure_identity(%HumanUser{} = human) do
    case Identity.ensure_identity(identity_request(human)) do
      {:ok, %{status: :ready}} ->
        {:ok, {:ready, human}}

      {:ok, %{status: :needs_wallet_signature} = state} ->
        {:ok, {:signature_required, human, signature_attrs(state)}}

      {:error, :wallet_required} ->
        {:error, :wallet_address_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ready_inbox_id(HumanUser.t()) ::
          {:ok, String.t()} | {:error, :wallet_address_required | :xmtp_identity_required}
  def ready_inbox_id(%HumanUser{} = human) do
    case Identity.ready_inbox_id(principal(human), human.xmtp_inbox_id) do
      {:ok, inbox_id} -> {:ok, inbox_id}
      {:error, :wallet_required} -> {:error, :wallet_address_required}
      {:error, _reason} -> {:error, :xmtp_identity_required}
    end
  end

  @spec complete_identity(HumanUser.t(), String.t(), map()) ::
          {:ok, HumanUser.t()} | {:error, term()}
  def complete_identity(%HumanUser{} = human, wallet_address, attrs)
      when is_binary(wallet_address) and is_map(attrs) do
    wallet_address = String.downcase(wallet_address)

    with {:ok, expected_wallet_address} <- required_string(attrs, "wallet_address"),
         :ok <- ensure_wallet_match(wallet_address, expected_wallet_address),
         {:ok, client_id} <- required_string(attrs, "client_id"),
         {:ok, request_id} <- required_string(attrs, "signature_request_id"),
         {:ok, signature} <- required_string(attrs, "signature"),
         {:ok, %{inbox_id: inbox_id}} <-
           Identity.complete_signature(%{
             runtime: @runtime_name,
             wallet_address: wallet_address,
             client_id: client_id,
             request_id: request_id,
             signature: signature
           }) do
      Accounts.update_human(human, %{
        "wallet_address" => wallet_address,
        "xmtp_inbox_id" => inbox_id
      })
    end
  end

  defp identity_request(%HumanUser{} = human) do
    %{
      runtime: @runtime_name,
      principal: principal(human),
      stored_inbox_id: human.xmtp_inbox_id
    }
  end

  defp principal(%HumanUser{} = human) do
    %{
      id: human.id,
      kind: :human,
      wallet_address: human.wallet_address,
      wallet_addresses: human.wallet_addresses,
      inbox_id: human.xmtp_inbox_id,
      display_name: human.display_name
    }
  end

  defp signature_attrs(%{signature_request: request, wallet_address: wallet_address}) do
    %{
      "inbox_id" => nil,
      "wallet_address" => wallet_address,
      "client_id" => request.client_id,
      "signature_request_id" => request.id,
      "signature_text" => request.text
    }
  end

  defp required_string(attrs, key) do
    case normalize_string(Map.get(attrs, key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp ensure_wallet_match(wallet_address, expected_wallet_address) do
    if String.downcase(wallet_address) == String.downcase(expected_wallet_address) do
      :ok
    else
      {:error, :wallet_address_mismatch}
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
