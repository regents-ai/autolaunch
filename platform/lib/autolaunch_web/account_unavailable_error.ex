defmodule AutolaunchWeb.AccountUnavailableError do
  @moduledoc """
  The account an agent's pairing names could not be read just now, when the
  shared agent requests (`RegentAgents.HTTP`) ask this site for it
  (`Autolaunch.Agents.paired_account/1`), which can only answer with an account
  or with none. The agent gets 503 `account_unavailable`
  (`AutolaunchWeb.ErrorJSON`), as the site's own agent routes answer it
  (`AutolaunchWeb.Plugs.AgentAccess`), never a missing person or a missing
  pairing.
  """
  defexception message: "the paired person's account could not be read just now",
               plug_status: 503
end
