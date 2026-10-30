defmodule AutolaunchWeb.Components.ShareMarket do
  @moduledoc """
  The "Share" button of the covered calls page (`:covered_calls`, by the
  market's symbol) and of the Isolated Exposure to After-hours Stocks page (`:exposure`, by the
  series' address): the share window (`AutolaunchWeb.Components.ShareDialog`)
  with the market's picture, a post naming it, and its share video.

  The video is the one for everyone. A signed-in person with a wallet also
  gets a switch, off as the window opens, that makes their own video instead,
  with the calls or the tokens their wallet holds, so nothing about their
  wallet is shown until they choose it and see it.
  """
  use Phoenix.Component

  alias AutolaunchWeb.Components.ShareDialog
  alias AutolaunchWeb.{ShareCard, ShareVideo}

  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:covered_calls, :exposure]
  attr :subject, :string, required: true, doc: "the market's symbol, or the series' address"

  attr :account_control, :map,
    required: true,
    doc: "who is signed in, as the page's top bar has it"

  def share_market(assigns) do
    now = DateTime.utc_now()
    %{kind: kind, subject: subject} = assigns
    wallet = wallet(assigns.account_control)

    assigns =
      assign(assigns,
        message: message(kind, subject),
        image: ShareCard.market_image_url(kind, subject, now),
        video: ShareVideo.market_url(kind, subject, nil, now),
        video_mine: wallet && ShareVideo.market_url(kind, subject, wallet, now),
        mine_label: mine_label(kind),
        video_name: video_name(kind, subject)
      )

    ~H"""
    <ShareDialog.share_dialog
      id={@id}
      label="Share"
      message={@message}
      image={@image}
      video={@video}
      video_mine={@video_mine}
      mine_label={@mine_label}
      video_name={@video_name}
    />
    """
  end

  defp wallet(%{kind: :signed_in, wallet_address: wallet}) when is_binary(wallet), do: wallet
  defp wallet(_signed_out), do: nil

  # The post names the product and links its page, as the page's own details do.
  defp message(:covered_calls, symbol) do
    meta = ShareCard.market_meta(:covered_calls, symbol)
    "#{meta.title} (Base): $#{symbol}. #{meta.url}"
  end

  defp message(:exposure, series) do
    meta = ShareCard.market_meta(:exposure, series)
    "#{meta.title} (Base). #{meta.url}"
  end

  defp mine_label(:covered_calls), do: "My calls"
  defp mine_label(:exposure), do: "My holdings"

  defp video_name(:covered_calls, symbol), do: "#{symbol}-covered-calls-autolaunch.mp4"
  defp video_name(:exposure, _series), do: "after-hours-autolaunch.mp4"
end
