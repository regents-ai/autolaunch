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
  end
end
