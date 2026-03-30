defmodule AutolaunchWeb.Api.ContractsError do
  @moduledoc false

  alias AutolaunchWeb.ApiError

  def render(conn, {:error, reason}) do
    case translate(reason) do
      {status, code, message} -> ApiError.render(conn, status, code, message)
    end
  end

  def translate(:not_found),
    do: {:not_found, "contract_scope_not_found", "Contract scope was not found"}

  def translate(:forbidden),
    do: {:forbidden, "contract_scope_forbidden", "Contract action is not allowed"}

  def translate(:subject_lookup_failed),
    do: {:internal_server_error, "subject_lookup_failed", "Subject state could not be loaded"}

  def translate(:unsupported_action),
    do: {:unprocessable_entity, "unsupported_contract_action", "Contract action is not supported"}

  def translate(:ingress_not_found),
    do: {:not_found, "ingress_not_found", "Ingress address does not belong to this subject"}

  def translate(:invalid_address),
    do: {:unprocessable_entity, "invalid_address", "Address is invalid"}

  def translate(:invalid_uint),
    do: {:unprocessable_entity, "invalid_amount", "Amount must be a whole onchain unit"}

  def translate(:invalid_string),
    do: {:unprocessable_entity, "invalid_label", "Text value is required"}

  def translate(:invalid_boolean),
    do: {:unprocessable_entity, "invalid_boolean", "Boolean flag is invalid"}

  def translate(reason) when is_atom(reason),
    do: {:unprocessable_entity, "contract_prepare_invalid", Atom.to_string(reason)}

  def translate(_reason),
    do: {:unprocessable_entity, "contract_prepare_invalid", "unexpected_error"}
end
