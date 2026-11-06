defmodule AutolaunchWeb.PairLive do
  @moduledoc """
  The page a "Pair New Agent" link opens: `/pair?to=<path>`, where `to` is a
  page on this site. A person pairs their agent in the same pairing box as the
  pairing window's (`AutolaunchWeb.PairingBox`), and the message they paste ends by
  sending the agent to that page once it is paired. A link with no `to`, or one
  that is not a page on this site, opens plain pairing. Signed out, it shows the
  shared signed-out section with the site's own Sign in button.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  # A page on this site: one leading "/", never "//" or "/\", which browsers read
  # as another site, and no spaces or control characters.
  @page ~r|\A/(?![/\\])[^\s\\\x00-\x1f\x7f]{0,511}\z|u

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, AutolaunchWeb.PublicDocuments.page("/pair"))}

  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, start: start(params))}

  @doc "The page a pairing link names, or nil when it names none on this site."
  @spec start(map()) :: String.t() | nil
  def start(%{"to" => to}) when is_binary(to), do: if(to =~ @page, do: to)
  def start(_params), do: nil

  def render(assigns) do
    assigns = assign(assigns, :current_human_id, current_human_id(assigns.access_context))

    ~H"""
    <article id="pair-page" class="autolaunch-account-page pair-page">
      <header class="autolaunch-heading">
        <h1>
          Pair New Agent
          <Regent.Primitives.tip id="pair-about" label="About Pair New Agent">
            Pair your agent with your account, then send it the message.
          </Regent.Primitives.tip>
        </h1>
      </header>
      <p :if={@start} id="pair-start">
        Once paired, it starts at <a href={@start}>{AutolaunchWeb.Endpoint.url() <> @start}</a>
      </p>
      <Regent.Account.signed_out
        :if={!@current_human_id}
        id="pair-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <.live_component
        :if={@current_human_id}
        module={AutolaunchWeb.PairingBox}
        id="pair-pairing-box"
        session_lease={@session_lease}
        account={signed_in_account(@access_context)}
        start={@start}
      />
    </article>
    """
  end

  defp signed_in_account(%{principal: {:human, account}}), do: account
end
