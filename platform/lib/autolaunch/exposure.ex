defmodule Autolaunch.Exposure do
  @moduledoc """
  Exposure on Base stock tokens: one stock token split, for one trading week,
  into an After-hours token that carries the stock's moves from each close to
  the next open and a Market-hours token that carries its moves from each open
  to the close. The factory (`contracts/exposure-v2`) opens one series a week,
  on its first deposit; the series contracts are the record.
  """

  use Ash.Domain, otp_app: :autolaunch

  @doc "The refusal an operation answered with, as the atom its surfaces turn into words."
  def reason(%{errors: [%{error: reason} | _]}) when is_atom(reason), do: reason
  def reason(reason) when is_atom(reason), do: reason
  def reason(_error), do: :chain_unavailable

  @doc """
  The terms text the site has for `hash`, the keccak256 a series holds as
  `termsHash`: the file named by the hash itself, the exact bytes it was taken
  from. A week whose hash has no file here has no terms on the site.
  """
  # The file is named by the hash, checked to be 32 bytes of hex first.
  # sobelow_skip ["Traversal.FileModule"]
  def terms("0x" <> hex) when byte_size(hex) == 64 do
    with {:ok, _bytes} <- Base.decode16(hex, case: :lower),
         {:ok, text} <-
           File.read(Application.app_dir(:autolaunch, "priv/exposure_terms/0x#{hex}.md")) do
      {:ok, text}
    else
      _unknown -> {:error, :unknown_terms}
    end
  end

  def terms(_hash), do: {:error, :unknown_terms}

  resources do
    resource Autolaunch.Exposure.Series do
      define :exposure_weeks, action: :list
      define :exposure_week, action: :week, args: [:week]
      define :exposure_holdings, action: :holdings, args: [:week]
      define :exposure_portfolio, action: :portfolio
      define :prepare_exposure, action: :prepare, args: [:week, :kind]
    end
  end
end
