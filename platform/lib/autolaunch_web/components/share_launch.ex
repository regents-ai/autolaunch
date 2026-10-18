defmodule AutolaunchWeb.Components.ShareLaunch do
  @moduledoc """
  The "Share" button of a launch's auction or token page, and of each launch
  on Portfolio: the share window (`AutolaunchWeb.Components.ShareDialog`) with
  the launch's picture, a post naming it, and its share video. A signed-in
  person's video is their own wallet's, with whatever they have in the launch;
  anyone else's is the launch's own. While the auction runs, all of it is the
  auction's; once it has graduated, the token's.
  """
  use Phoenix.Component

  alias AutolaunchWeb.Components.ShareDialog
  alias AutolaunchWeb.{Paths, ShareCard, ShareVideo}
  alias AutolaunchWeb.ShareCard.Draw

  attr :id, :string, required: true
  attr :auction, :map, required: true, doc: "the launch's auction, loaded with `path_tail`"

  attr :account_control, :map,
    required: true,
    doc: "who is signed in, as the page's top bar has it"

  def share_launch(assigns) do
    now = DateTime.utc_now()
    auction = assigns.auction
    symbol = Draw.plain(auction.token_symbol)
    chain = Draw.chain_name(Draw.chain(auction))

    assigns =
      assign(assigns,
        message: message(auction, symbol, chain),
        image: image(auction, now),
        video: ShareVideo.url(auction, wallet(assigns.account_control), now),
        video_everyone: wallet(assigns.account_control) && ShareVideo.url(auction, nil, now),
        video_name: "#{symbol}-autolaunch.mp4"
      )

    ~H"""
    <ShareDialog.share_dialog
      id={@id}
      label="Share"
      message={@message}
      image={@image}
      video={@video}
      video_everyone={@video_everyone}
      video_name={@video_name}
    />
    """
  end

  defp wallet(%{kind: :signed_in, wallet_address: wallet}) when is_binary(wallet), do: wallet
  defp wallet(_signed_out), do: nil

  defp message(%{state: :graduated} = auction, symbol, chain),
    do: "$#{symbol} on Autolaunch (#{chain}). #{Paths.token_url(auction)}"

  defp message(auction, symbol, chain),
    do: "$#{symbol} is in its auction on Autolaunch (#{chain}). #{Paths.auction_url(auction)}"

  defp image(%{state: :graduated} = auction, now), do: ShareCard.token_image_url(auction, now)
  defp image(auction, now), do: ShareCard.auction_image_url(auction, now)
end
