defmodule Autolaunch.SubjectWalletChainClient do
  @moduledoc """
  The one Base boundary a subject wallet action has.

  `snapshot/1` answers the whole reviewed question at once — the splitter's own
  bindings and treasury, the receiver's bindings and canonical economics where a
  payment needs them, the active wallet's three balances and stake, its current
  claimables, and the allowance standing between it and the spender. There is no
  partial answer: a review is derived from one snapshot or from none.

  `verify/3` is read-only. The browser reports a hash and stops; whether that
  hash confirmed, reverted or contradicted its own review is decided here.
  """

  @type outcome :: %{
          :outcome => :pending | :confirmed | :reverted | :unverified,
          optional(:result) => map()
        }

  @callback snapshot(map()) :: {:ok, map()} | {:error, atom()}
  @callback verify(map(), :approval | :action, String.t()) :: {:ok, outcome()} | {:error, atom()}

  def module do
    Application.get_env(
      :autolaunch,
      :autolaunch_subject_wallet_chain_client,
      Autolaunch.SubjectWalletRpcClient
    )
  end
end
