defmodule Autolaunch.Agents.HostedAddress do
  @moduledoc """
  The wallet of each account's hosted identity: the one identity an app such as
  Claude keeps when its person connects it here, held by the sign-in service.
  It never changes for an account on this site, so once the service has given it
  (`RegentMCPAgents.address/1`) it is kept on this machine and every later call
  from the app reads it here. An answer that failed is not kept: the next call
  asks again.
  """

  @cache :autolaunch_hosted_address

  @doc "The cache's name, for the application's supervisor."
  def cache, do: @cache

  @doc "The wallet of the identity the connection's account keeps here."
  @spec read(map()) :: {:ok, String.t()} | {:error, :unavailable}
  def read(%{subject: subject} = principal) do
    {_kind, answer} = Cachex.fetch(@cache, subject, fn _subject -> ask(principal) end)
    answer
  end

  # Two calls that miss at once share one ask (Cachex.fetch).
  defp ask(principal) do
    case RegentMCPAgents.address(principal) do
      {:ok, address} -> {:commit, {:ok, address}}
      {:error, _reason} -> {:ignore, {:error, :unavailable}}
    end
  end
end
