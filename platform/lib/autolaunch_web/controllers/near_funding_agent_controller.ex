defmodule AutolaunchWeb.NearFundingAgentController do
  @moduledoc """
  Funding a bid from NEAR for a signed, paired agent, acting for the person it
  is paired with, as the bid page does for the person (`Autolaunch.Funding`):
  a quote of the NEAR that buys an exact amount of USDC on Base, starting a
  funding to get the deposit address, and reading a funding's status now. The
  USDC always goes to the person's own signed-in wallet; the only address the
  agent gives is the NEAR account a refund goes to. The site only quotes and
  reads: NEAR is sent from the person's own NEAR wallet.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Funding

  plug AutolaunchWeb.Plugs.AgentAccess

  @try_again "Try again in a moment."
  @not_again "Sending the same request again will not help."

  @refusals %{
    unknown_auction:
      {:not_found, "There is no auction with that id on this site.",
       "List auctions with GET /api/v1/auctions. #{@not_again}"},
    invalid_amount:
      {:unprocessable_entity,
       "usdc_amount must be a whole number of USDC base units, at least 1.",
       "Send usdc_amount as an integer in USDC's 6 decimals: 5000000 is 5 USDC. #{@not_again}"},
    invalid_refund_account:
      {:unprocessable_entity, "refund_to must be a NEAR account name.",
       "Send refund_to as your person's NEAR account, such as name.near, where a refund goes. #{@not_again}"},
    wallet_required:
      {:conflict, "Your person's account has no wallet to receive the USDC.",
       "Ask your person to sign in with their wallet on any Regent site, then send the request again."},
    wrong_signer:
      {:forbidden, "Your person's signed-in wallet is not one of their account's own wallets.",
       "Ask your person to sign in again with their wallet, then send the request again."},
    authentication_required:
      {:unauthorized, "Your person's account could not be read.", @try_again},
    not_found:
      {:not_found, "There is no funding with that id for your person.",
       "Use the id that starting the funding answered. #{@not_again}"},
    near_unavailable:
      {:service_unavailable, "The NEAR Intents service could not be reached just now.",
       @try_again}
  }

  def quote_funding(conn, %{"id" => auction_id}) do
    auction_id
    |> Funding.quote_near_funding(conn.body_params["usdc_amount"], actor: conn.assigns.actor)
    |> answer(conn, :ok)
  end

  def start(conn, %{"id" => auction_id}) do
    auction_id
    |> Funding.start_near_funding(
      conn.body_params["usdc_amount"],
      conn.body_params["refund_to"],
      actor: conn.assigns.actor
    )
    |> answer(conn, :created)
  end

  def show(conn, %{"id" => id}) do
    actor = conn.assigns.actor

    with {:ok, funding} <- Funding.near_funding(id, actor: actor) do
      Funding.refresh_near_funding(funding, actor: actor)
    end
    |> answer(conn, :ok)
  end

  defp answer({:ok, result}, conn, status),
    do: conn |> put_status(status) |> json(%{data: present(result)})

  defp answer({:error, error}, conn, _status) do
    reason = Funding.reason(error)
    {status, message, hint} = Map.fetch!(@refusals, reason)

    conn
    |> put_status(status)
    |> json(%{error: %{code: reason, message: message, hint: hint}})
  end

  defp present(%Autolaunch.NearFunding{} = funding) do
    Map.take(funding, [
      :id,
      :auction_id,
      :recipient,
      :refund_to,
      :usdc_amount,
      :near_amount,
      :near_amount_raw,
      :deposit_address,
      :deadline,
      :time_estimate_s,
      :state,
      :origin_tx,
      :destination_tx,
      :inserted_at,
      :updated_at
    ])
  end

  defp present(quote), do: quote
end
