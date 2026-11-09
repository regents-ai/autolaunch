defmodule Autolaunch.Exposure do
  @moduledoc """
  Exposure on Base stock tokens: one stock token split, for a fixed term, into
  an After-hours token that carries the stock's moves from each close to the
  next open and a Market-hours token that carries its moves from each open to
  the close. The series contract (`contracts/exposure`) is the record; see
  `platform/docs/after-hours-exposure-spec.md`.
  """

  use Ash.Domain, otp_app: :autolaunch

  @doc "The refusal an operation answered with, as the atom its surfaces turn into words."
  def reason(%{errors: [%{error: reason} | _]}) when is_atom(reason), do: reason
  def reason(reason) when is_atom(reason), do: reason
  def reason(_error), do: :chain_unavailable

  resources do
    resource Autolaunch.Exposure.Series do
      define :exposure_series_list, action: :list
      define :exposure_series, action: :series, args: [:series]
      define :exposure_holdings, action: :holdings, args: [:series]
      define :prepare_exposure, action: :prepare, args: [:series, :kind]
    end

    resource Autolaunch.Exposure.Recording do
      define :add_recording, action: :add
    end

    resource Autolaunch.Exposure.RecorderTransaction do
      define :record_recorder_transaction, action: :record

      define :unsettled_recorder_transaction,
        action: :unsettled,
        args: [:recording_id],
        not_found_error?: false

      define :highest_recorder_nonce,
        action: :highest_nonce,
        args: [:chain_id, :signer],
        not_found_error?: false

      define :settle_recorder_transaction, action: :settle, args: [:outcome]
    end
  end
end
