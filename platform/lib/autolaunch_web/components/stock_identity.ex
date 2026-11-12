defmodule AutolaunchWeb.Components.StockIdentity do
  @moduledoc """
  A stock token's identity, in the same words wherever the site names one: its
  issuer, its chain and, where a person decides or signs, its exact contract
  address through `Regent.Primitives.address` (short form, copy icon, explorer
  arrow). A ticker or a company's name never names a stock token alone: each
  issuer has its own token for the same company, and neither is the share.

  The issuer is `Autolaunch.Stocks.Assets.issuer/1`'s, the chain's own.
  """
  use Phoenix.Component

  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Assets

  attr :chain, :atom, required: true, values: [:base, :robinhood]

  attr :address, :string,
    default: nil,
    doc: "the token's contract address; left out in a list whose rows open the stock's own page"

  attr :id, :string, default: nil, doc: "the address piece's id, wherever an address is given"

  attr :explorer, :string,
    default: nil,
    doc:
      "the chain `Regent.Primitives.address` opens the address on, when the page already knows it"

  attr :class, :any, default: nil

  @doc "The issuer and chain, then the address when one is given."
  def stock_identity(assigns) do
    ~H"""
    <span class={["stock-identity", @class]}>
      <span class="stock-identity__words">{words(@chain)}</span>
      <Regent.Primitives.address
        :if={@address}
        id={@id}
        address={@address}
        chain={@explorer || explorer(@chain)}
      />
    </span>
    """
  end

  @doc "The issuer and chain in a few words, as `Coinbase token · Base`."
  @spec words(:base | :robinhood) :: String.t()
  def words(chain), do: "#{Assets.issuer(chain)} token · #{chain_name(chain)}"

  @doc "A stock token named in a sentence, as `AMZNc, a Coinbase stock token on Base`."
  @spec sentence(:base | :robinhood, String.t()) :: String.t()
  def sentence(chain, symbol),
    do: "#{symbol}, a #{Assets.issuer(chain)} stock token on #{chain_name(chain)}"

  defp chain_name(:base), do: "Base"
  defp chain_name(:robinhood), do: "Robinhood Chain"

  # A local test chain has no explorer.
  defp explorer(:base), do: if(Lab.test_chain?(), do: "test", else: "base")
  defp explorer(:robinhood), do: if(RobinhoodLab.test_chain?(), do: "test", else: "robinhood")
end
