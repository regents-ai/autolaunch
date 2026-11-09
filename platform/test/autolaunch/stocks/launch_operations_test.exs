defmodule Autolaunch.Stocks.LaunchOperationsTest do
  @moduledoc """
  Every Stocks and Robinhood wallet action binds its review to the signed-in
  account's own wallet through `LaunchOperations.signed_in_wallet/2`: a
  person, a well-formed address, the session lease, that lease's own account
  and a wallet the account links, refused in that order.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks.LaunchOperations

  @other_wallet "0x2222222222222222222222222222222222222222"

  setup :bidder

  test "binds to a wallet the leased account links and refuses anything else, in order",
       %{actor: actor, opts: opts, wallet: wallet} do
    lease = opts[:context].session_lease

    assert {:ok, %{actor: ^actor, signer: ^wallet, lease: ^lease}} =
             LaunchOperations.signed_in_wallet(wallet, opts)

    assert {:error, %{reason: :authentication_required}} =
             LaunchOperations.signed_in_wallet("not an address", Keyword.delete(opts, :actor))

    assert {:error, %{reason: :invalid_address}} =
             LaunchOperations.signed_in_wallet("not an address", Keyword.delete(opts, :context))

    assert {:error, %{reason: :session_lease_required}} =
             LaunchOperations.signed_in_wallet(@other_wallet, Keyword.delete(opts, :context))

    stranger = %Human{human_account_id: actor.human_account_id + 1}

    assert {:error, %{reason: :session_unavailable}} =
             LaunchOperations.signed_in_wallet(@other_wallet, Keyword.put(opts, :actor, stranger))

    assert {:error, %{reason: :wrong_signer}} =
             LaunchOperations.signed_in_wallet(@other_wallet, opts)
  end
end
