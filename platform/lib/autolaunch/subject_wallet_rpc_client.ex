defmodule Autolaunch.SubjectWalletRpcClient do
  @moduledoc """
  The production Base client for subject wallet actions, which prepares nothing yet.

  A review needs the launch's real splitter and canonical receiver, and both are
  C5 address and runtime evidence that `490.8.2/.3` projection has still to make
  canonical. Until then no address this lane could read is admitted evidence, so
  `snapshot/1` refuses before it opens a connection rather than reviewing against
  a value nobody has frozen.
  """

  @behaviour Autolaunch.SubjectWalletChainClient

  @impl true
  def snapshot(_request), do: {:error, :subject_wallet_preparation_unavailable}
end
