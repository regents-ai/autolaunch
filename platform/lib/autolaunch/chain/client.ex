defmodule Autolaunch.Chain.Client do
  @moduledoc """
  JSON-RPC reads at the latest block of the chain a review names.

  `RegentChain.Outcome` reads sent steps through `transaction/2` and `receipt/2`.
  Every read is at `latest`: never count confirmations and never wait for `safe`
  or `finalized`. The read goes through the site's own door for the review's
  chain id, never the public door the review hands to the wallet.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @doc "The chain a review names for `config`'s deployment: its id, network name and public door."
  def chain(%{chain_id: chain_id, public_rpc_url: rpc_url}),
    do: %{chain_id: chain_id, name: network_name(chain_id), rpc_url: rpc_url}

  @doc """
  Every chain this site's reviews can name, as `chain/1` names it: the Base
  deployment's, then the Robinhood deployment's when the site has one. The
  page gives the list to Privy, Base as the network wallets start on, so the
  list starts with Base or is empty: a site without a Base deployment has no
  wallet chain.
  """
  def chains do
    case {Lab.current(), RobinhoodLab.current()} do
      {{:ok, base}, {:ok, robinhood}} -> [chain(base), chain(robinhood)]
      {{:ok, base}, {:error, _reason}} -> [chain(base)]
      {{:error, _reason}, _robinhood} -> []
    end
  end

  @doc "The network name every page shows for `chain_id`."
  def network_name(chain_id) do
    if RobinhoodLab.chain?(chain_id),
      do: RobinhoodLab.network_name(chain_id),
      else: Lab.network_name(chain_id)
  end

  @doc "The transaction sent as `hash`, or `nil` while the chain does not know it."
  def transaction(chain, hash), do: read(chain, "eth_getTransactionByHash", [hash])

  @doc "The receipt for `hash`, or `nil` while it has not landed."
  def receipt(chain, hash), do: read(chain, "eth_getTransactionReceipt", [hash])

  defp read(%{chain_id: chain_id}, method, params) do
    with {:ok, config} <- deployment(chain_id) do
      Rpc.request(method, params, rpc_opts(config))
    end
  end

  defp deployment(chain_id) do
    cond do
      RobinhoodLab.chain?(chain_id) -> RobinhoodLab.current()
      chain_id == Lab.chain_id() -> Lab.current()
      true -> {:error, :unknown_chain}
    end
  end

  defp rpc_opts(%{chain_id: chain_id} = config) do
    if RobinhoodLab.chain?(chain_id),
      do: RobinhoodLab.rpc_opts(config),
      else: Lab.rpc_opts(config)
  end
end
