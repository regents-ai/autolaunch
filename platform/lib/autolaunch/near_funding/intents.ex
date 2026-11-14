defmodule Autolaunch.NearFunding.Intents do
  @moduledoc """
  The NEAR Intents 1Click service as a funding sees it, through
  `RegentNearIntents` (swapped in tests by `:near_intents_client`): a quote of
  the NEAR that buys `usdc_amount` USDC on Base for the acting account's own
  signed-in wallet, and the status of a swap by its deposit address. The
  recipient is always that wallet, never one the request names.
  """

  alias Autolaunch.CoveredCalls.Signer

  @states [:pending_deposit, :processing, :success, :refunded, :failed]

  # The service asks every quote for a NEAR account to refund to. A dry quote
  # opens no deposit address, so nothing can be refunded and any account does:
  # this is the one the service's own dry quote was taken with.
  @dry_refund_to "test.near"

  @doc """
  The terms for funding `usdc_amount` USDC on `auction_id`, quoted now. With
  `refund_to` nil the quote is dry and has no deposit address; with a NEAR
  account it opens one, refunding to that account.
  """
  @spec quote(term(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def quote(actor, auction_id, usdc_amount, refund_to) do
    with :ok <- auction(auction_id),
         {:ok, recipient} <- Signer.wallet(actor, nil),
         {:ok, quote} <- ask(usdc_amount, recipient, refund_to) do
      {:ok,
       %{
         usdc_amount: usdc_amount,
         near_amount: near(quote.amount_in_formatted),
         near_amount_raw: Integer.to_string(quote.amount_in),
         time_estimate_s: quote.time_estimate_s,
         recipient: recipient,
         deposit_address: quote.deposit_address,
         deadline: quote.deadline
       }}
    end
  end

  @doc "How the swap sent to `deposit_address` is going."
  @spec status(String.t()) :: {:ok, map()} | {:error, :near_unavailable}
  def status(deposit_address) do
    case client().status(deposit_address) do
      {:ok, %{state: state} = status} when state in @states ->
        {:ok, Map.take(status, [:state, :origin_tx, :destination_tx])}

      _unread ->
        {:error, :near_unavailable}
    end
  end

  defp auction(auction_id) do
    case Autolaunch.get_public_auction(auction_id, actor: nil) do
      {:ok, %{}} -> :ok
      _unknown -> {:error, :unknown_auction}
    end
  end

  defp ask(usdc_amount, recipient, refund_to) do
    case client().quote(%{
           usdc_amount: usdc_amount,
           recipient: recipient,
           refund_to: refund_to || @dry_refund_to,
           dry: is_nil(refund_to)
         }) do
      {:ok, quote} -> {:ok, quote}
      {:error, _error} -> {:error, :near_unavailable}
    end
  end

  # The NEAR to send, rounded up to the thousandth so it is never short.
  defp near(formatted) do
    formatted |> Decimal.new() |> Decimal.round(3, :ceiling) |> Decimal.to_string(:normal)
  end

  defp client, do: Application.get_env(:autolaunch, :near_intents_client, RegentNearIntents)
end
