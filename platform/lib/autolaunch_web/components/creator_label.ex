defmodule AutolaunchWeb.Components.CreatorLabel do
  @moduledoc """
  Who launched an auction or token, in a word or two, the same on every list
  row, auction and token page and share picture: the creator's first account
  the auction page shows as ownership checked (X, Company X, ENS, then
  GitHub), else the launching wallet, shortened.
  """
  use Phoenix.Component

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias AutolaunchWeb.Components.{BidPlaced, MarketCard}

  @doc """
  The creator's name for `auction`, given its creator's connected accounts:
  its words, where it leads and what it says on hover. Nil when the auction
  names neither an account nor a wallet.
  """
  @spec name(map(), map() | nil) :: %{text: String.t(), url: String.t(), title: String.t()} | nil
  def name(auction, connections) do
    case MarketCard.connection_list(connections) do
      [account | _rest] ->
        %{
          text: account.handle,
          url: account.url,
          title: "#{account.label} #{account.handle}, ownership checked"
        }

      [] ->
        wallet(auction)
    end
  end

  defp wallet(%{creator_address: address, chain_id: chain_id}) when is_binary(address) do
    chain = if RobinhoodLab.chain?(chain_id), do: :robinhood, else: :base

    %{
      text: RegentFormat.short_address(address),
      url: BidPlaced.address_url(chain, address),
      title: address
    }
  end

  defp wallet(_auction), do: nil

  attr :auction, :map, required: true, doc: "the auction, or a token's auction"
  attr :connections, :map, default: nil, doc: "the creator's connected accounts"
  attr :class, :string, default: nil

  @doc "\"by\" and the creator's name, which opens their account or their wallet on the explorer."
  def creator(assigns) do
    assigns = assign(assigns, :name, name(assigns.auction, assigns.connections))

    ~H"""
    <p :if={@name} class={["creator-label", @class]}>
      by
      <a href={@name.url} title={@name.title} target="_blank" rel="noopener noreferrer">{@name.text}</a>
    </p>
    """
  end
end
