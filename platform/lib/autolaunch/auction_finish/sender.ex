defmodule Autolaunch.AuctionFinish.Sender do
  @moduledoc """
  Sends `migrate` from the finishing wallet, and settles what it sent, through
  `Autolaunch.Chain.Sender`: every signed `migrate` is an
  `AuctionFinish.Transaction`, recorded before it is broadcast, and a launch
  with one the chain has not settled is never sent another.
  """

  @behaviour Autolaunch.Chain.Sender.Ledger

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Sender, Wallet}

  @actor %System{}

  @doc """
  Settles the launch's recorded transaction, if it has one: `{:ok, :clear}`
  when there is nothing left unsettled, `{:ok, :waiting}` while there is.
  """
  def settle(pad, finish), do: Sender.settle(__MODULE__, chain(pad), finish)

  @doc "Reserves a nonce, signs and records the call, then broadcasts it."
  def send_call(pad, finish, call),
    do:
      Sender.send_call(
        __MODULE__,
        chain(pad),
        finish,
        Wallet.configured!(:auction_finisher_key),
        call
      )

  defp chain(pad), do: %{chain_id: pad.chain_id, opts: pad.opts}

  @impl true
  def unsettled(finish),
    do: Autolaunch.unsettled_auction_finish_transaction(finish.id, actor: @actor)

  @impl true
  def highest_nonce(chain_id, signer),
    do: Autolaunch.highest_auction_finish_nonce(chain_id, signer, actor: @actor)

  @impl true
  def record(finish, attrs),
    do:
      Autolaunch.record_auction_finish_transaction(
        Map.put(attrs, :auction_finish_id, finish.id),
        actor: @actor
      )

  @impl true
  def settle_transaction(transaction, outcome),
    do: Autolaunch.settle_auction_finish_transaction(transaction, outcome, actor: @actor)

  @impl true
  def label, do: "auction finisher"
end
