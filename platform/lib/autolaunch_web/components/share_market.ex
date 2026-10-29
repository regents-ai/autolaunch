defmodule AutolaunchWeb.Components.ShareMarket do
  @moduledoc """
  The "Share" button of the covered calls page (`:covered_calls`, by the
  market's symbol) and of the After-hours Exposure page (`:exposure`, by the
  series' address): the share window (`AutolaunchWeb.Components.ShareDialog`)
  with the market's picture, a post naming it, and its share video.

  The video is the one for everyone. A signed-in person with a wallet also
  gets a switch, off as the window opens, that makes their own video instead,
  with the calls or the tokens their wallet holds, so nothing about their
  wallet is shown until they choose it and see it.
  """
  use Phoenix.Component

  use AutolaunchWeb, :verified_routes

  alias AutolaunchWeb.Components.ShareDialog
  alias AutolaunchWeb.{PublicDocuments, ShareCard, ShareVideo}

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

  # The post names the product as its page does, so a new title reaches it.
  defp message(:covered_calls, symbol),
    do:
      "#{title("/covered-calls")} on $#{symbol}, on Autolaunch (Base). #{url(~p"/covered-calls")}"

  defp message(:exposure, series),
    do:
      "#{title("/after-hour-stocks")} on Autolaunch (Base). #{url(~p"/after-hour-stocks?#{[series: series]}")}"

  defp title(path), do: Keyword.fetch!(PublicDocuments.page(path), :page_title)

  defp mine_label(:covered_calls), do: "My calls"
  defp mine_label(:exposure), do: "My holdings"

  defp video_name(:covered_calls, symbol), do: "#{symbol}-covered-calls-autolaunch.mp4"
  defp video_name(:exposure, _series), do: "after-hours-autolaunch.mp4"
end
