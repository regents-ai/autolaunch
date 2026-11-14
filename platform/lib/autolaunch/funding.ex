defmodule Autolaunch.Funding do
  @moduledoc """
  Funding a bid from NEAR. The site quotes, through the NEAR Intents 1Click
  service, how much NEAR buys an exact amount of USDC on Base delivered to the
  acting account's own wallet, records the deposit address the person sends
  NEAR to from their own NEAR wallet, and reads how the swap is going
  (`Autolaunch.NearFunding`). The site only quotes and reads: it never holds or
  moves funds.
  """

  use Ash.Domain, otp_app: :autolaunch

  # An argument that does not cast or fails its constraint is refused by the
  # same atom a refusal from the service or the account would be.
  @argument_reasons %{
    auction_id: :unknown_auction,
    usdc_amount: :invalid_amount,
    refund_to: :invalid_refund_account
  }

  @doc "The refusal an operation answered with, as the atom its surfaces turn into words."
  def reason(%{errors: [%{error: reason} | _]}) when is_atom(reason), do: reason

  def reason(%{errors: [%{field: field} | _]}) when is_map_key(@argument_reasons, field),
    do: Map.fetch!(@argument_reasons, field)

  def reason(reason) when is_atom(reason), do: reason
  def reason(_error), do: :near_unavailable

  resources do
    resource Autolaunch.NearFunding do
      define :quote_near_funding, action: :quote, args: [:auction_id, :usdc_amount]
      define :start_near_funding, action: :start, args: [:auction_id, :usdc_amount, :refund_to]
      define :near_funding, action: :read, get_by: [:id]
      define :near_fundings_for, action: :for_auction, args: [:auction_id]
      define :refresh_near_funding, action: :refresh
    end
  end
end
