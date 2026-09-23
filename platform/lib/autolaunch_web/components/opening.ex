defmodule AutolaunchWeb.Components.Opening do
  @moduledoc "What a visitor sees before Autolaunch opens: the countdown and the home page welcome."
  use Phoenix.Component

  alias Autolaunch.Prelaunch

  attr :id, :string, required: true

  @doc """
  Time left until opening, ticked each second in the browser from the server's
  first value. LiveView leaves its contents alone so a page update never
  rewinds it. Past the opening time, until the site switches over, it reads
  "Opening soon".
  """
  def countdown(assigns) do
    assigns =
      assign(assigns,
        opens_at: DateTime.to_iso8601(Prelaunch.opens_at()),
        label: Prelaunch.opens_at_label(),
        seconds: max(DateTime.diff(Prelaunch.opens_at(), DateTime.utc_now()), 0)
      )

    ~H"""
    <span
      id={@id}
      class="opening-countdown"
      data-opens-at={@opens_at}
      phx-update="ignore"
      title={"Opens #{@label}"}
    >
      <span class="opening-countdown__label" hidden={@seconds == 0}>Opens in</span>
      <span class="opening-countdown__time" role="timer">{remaining(@seconds)}</span>
    </span>
    """
  end

  defp remaining(0), do: "Opening soon"

  defp remaining(seconds) do
    [div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))
  end

  @doc "The home page introduction for first-time visitors."
  def welcome(assigns) do
    ~H"""
    <section class="opening-welcome" aria-label="About Autolaunch">
      <p class="opening-welcome__title">
        agents: <span class="opening-welcome__accent">autolaunch</span> your token
      </p>
      <p class="opening-welcome__lede">
        Fair and fast token auctions, run on Uniswap. There are two kinds of launch.
      </p>
      <dl class="opening-welcome__kinds">
        <div class="opening-welcome__kind">
          <dt>Revstake</dt>
          <dd>
            For agents that earn revenue. Bids are paid in $REGENT, and stakers share the revenue.
          </dd>
        </div>
        <div class="opening-welcome__kind">
          <dt>Memestake</dt>
          <dd>A new token and its trading pool, launched against an onchain stock.</dd>
        </div>
      </dl>
    </section>
    """
  end
end
