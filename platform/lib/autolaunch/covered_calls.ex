defmodule Autolaunch.CoveredCalls do
  @moduledoc """
  Covered calls on Base stock tokens: a seller locks stock and lists calls on
  it; any person or agent buys them for a premium in USDC; during the 24 hours
  after the Friday expiry a holder may pay the strike for the stock. The
  contract (`contracts/covered-calls`) is the record; see
  `platform/docs/covered-calls-design.md`.
  """

  use Ash.Domain, otp_app: :autolaunch

  resources do
    resource Autolaunch.CoveredCalls.Market do
      define :covered_call_book, action: :book, args: [:symbol]
      define :covered_call_quote, action: :quote, args: [:symbol, :strike_per_token, :expiry]
      define :covered_call_positions, action: :positions, args: [:symbol]
      define :prepare_covered_call, action: :prepare, args: [:symbol, :kind]
    end
  end
end
