defmodule AutolaunchWeb.HomeLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.{Launch, Xmtp}
  alias AutolaunchWeb.Live.Refreshable
  alias AutolaunchWeb.LaunchComponents

  @poll_ms 15_000

  @operator_guides [
    %{
      id: "openclaw",
      eyebrow: "OpenClaw",
      title: "Give OpenClaw the whole launch run.",
      body:
        "Start with the wizard, let it gather what is missing, save the plan, and carry the launch through monitoring.",
      copy_label: "Copy OpenClaw brief",
      prompt: """
      Use Autolaunch to prepare and run a token launch for me.

      Start with `regent autolaunch prelaunch wizard`.
      Ask me for any missing launch details before you continue.
      Save the plan, validate it, publish it, run the launch, and monitor the auction.
      Stop for confirmation before every signing step and explain what happens next in plain English.
      """
    },
    %{
      id: "hermes",
      eyebrow: "Hermes",
      title: "Give Hermes the operator checklist.",
      body:
        "Use Hermes when you want a steadier back-and-forth: one saved plan, one launch run, and clear checkpoints along the way.",
      copy_label: "Copy Hermes brief",
      prompt: """
      Help me launch through Autolaunch as an operator.

      Begin with `regent autolaunch prelaunch wizard`.
      Keep the saved plan as the source of truth.
      Walk me through validate, publish, launch, and monitor in order.
      Before each signing step, tell me what it will do and what to check after it lands.
      """
    }
  ]

  @home_steps [
    %{
      title: "Start the wizard",
      body: "Save the launch plan first so your agent has one clean set of inputs to work from."
    },
    %{
      title: "Run the launch",
      body:
        "Validate, publish, run, and monitor from the same path instead of bouncing between tools."
    },
    %{
      title: "Come back here live",
      body:
        "Use the site to watch active auctions, inspect token pages, and stay on the wire once the market is moving."
    }
  ]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Xmtp.subscribe()
    end

    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> assign(:page_title, "Autolaunch")
     |> assign(:active_view, "home")
     |> assign(:operator_guides, @operator_guides)
     |> assign(:home_steps, @home_steps)
     |> assign(
       :privy_app_id,
       Keyword.get(Application.get_env(:autolaunch, :privy, []), :app_id, "")
     )
     |> assign(:xmtp_room, load_xmtp_panel(socket.assigns[:current_human]))
     |> assign_home_market()}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_home/1)}
  end

  def handle_info({:xmtp_public_room, :refresh}, socket) do
    {:noreply, assign(socket, :xmtp_room, load_xmtp_panel(socket.assigns.current_human))}
  end

  def handle_event("xmtp_send", %{"body" => body}, socket) do
    case Xmtp.send_public_message(socket.assigns.current_human, body) do
      {:ok, panel} ->
        {:noreply, assign(socket, :xmtp_room, panel)}

      {:error, reason} ->
        {:noreply, assign(socket, :xmtp_room, xmtp_error_panel(socket.assigns, reason))}
    end
  end

  def handle_event("xmtp_join", _params, socket) do
    case Xmtp.request_join(socket.assigns.current_human) do
      {:ok, panel} ->
        {:noreply, assign(socket, :xmtp_room, panel)}

      {:needs_signature, %{request_id: request_id, signature_text: signature_text, panel: panel}} ->
        {:noreply,
         socket
         |> assign(:xmtp_room, panel)
         |> push_event("xmtp:sign-request", %{
           request_id: request_id,
           signature_text: signature_text,
           wallet_address: panel.connected_wallet
         })}

      {:error, reason} ->
        {:noreply, assign(socket, :xmtp_room, xmtp_error_panel(socket.assigns, reason))}
    end
  end

  def handle_event(
        "xmtp_join_signature_signed",
        %{"request_id" => request_id, "signature" => signature},
        socket
      ) do
    case Xmtp.complete_join_signature(socket.assigns.current_human, request_id, signature) do
      {:ok, panel} ->
        {:noreply, assign(socket, :xmtp_room, panel)}

      {:error, reason} ->
        {:noreply, assign(socket, :xmtp_room, xmtp_error_panel(socket.assigns, reason))}
    end
  end

  def handle_event("xmtp_join_signature_failed", %{"message" => message}, socket) do
    {:noreply, update(socket, :xmtp_room, &Map.put(&1, :status, message))}
  end

  def handle_event("xmtp_heartbeat", _params, socket) do
    :ok = Xmtp.heartbeat(socket.assigns.current_human)
    {:noreply, socket}
  end

  def handle_event("xmtp_delete_message", %{"message_id" => message_id}, socket) do
    case Xmtp.moderator_delete_message(socket.assigns.current_human, message_id) do
      {:ok, panel} ->
        {:noreply, assign(socket, :xmtp_room, panel)}

      {:error, reason} ->
        {:noreply, assign(socket, :xmtp_room, xmtp_error_panel(socket.assigns, reason))}
    end
  end

  def handle_event("xmtp_kick_user", %{"target" => target}, socket) do
    case Xmtp.moderator_kick_user(socket.assigns.current_human, target) do
      {:ok, panel} ->
        {:noreply, assign(socket, :xmtp_room, panel)}

      {:error, reason} ->
        {:noreply, assign(socket, :xmtp_room, xmtp_error_panel(socket.assigns, reason))}
    end
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="home-page" class="al-home-layout">
        <div class="al-home-main">
          <section id="home-hero" class="al-panel al-home-hero" phx-hook="MissionMotion">
            <div class="al-home-hero-copy">
              <p class="al-kicker">Start here</p>
              <h2>Copy the wizard command. Let your agent carry the launch.</h2>
              <p class="al-subcopy">
                Save one plan, run one clean launch path, and come back here when the auction is live
                and token holders need action.
              </p>

              <div class="al-hero-actions">
                <button type="button" class="al-cta-link al-cta-link--primary" data-copy-value={wizard_command()}>
                  Copy wizard command
                </button>
                <.link navigate={~p"/launch-via-agent"} class="al-ghost">Operator path</.link>
              </div>

              <div class="al-launch-tags" aria-label="Homepage facts">
                <span class="al-launch-tag">OpenClaw or Hermes</span>
                <span class="al-launch-tag">Save one plan first</span>
                <span class="al-launch-tag">Watch the live auction here</span>
              </div>
              <p class="al-inline-note">
                Need the auction mechanics first?
                <.link navigate={~p"/how-auctions-work"} class="al-inline-link">Open the guide</.link>.
              </p>
            </div>

            <.terminal_command_panel
              kicker="Copy and paste"
              title="Wizard command"
              command={wizard_command()}
              output_label="What to run next"
              output={wizard_transcript()}
              copy_label="Copy command"
            />
          </section>

          <section
            id="home-operator-briefs"
            class="al-panel al-home-operator-briefs"
            phx-hook="MissionMotion"
          >
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Choose the operator</p>
                <h3>Pick the agent that should carry the run.</h3>
              </div>
            </div>

            <div class="al-home-brief-grid">
              <article :for={guide <- @operator_guides} class="al-home-brief-card">
                <p class="al-kicker">{guide.eyebrow}</p>
                <h3>{guide.title}</h3>
                <p>{guide.body}</p>

                <div class="al-choice-actions">
                  <button type="button" class="al-submit" data-copy-value={guide.prompt}>
                    {guide.copy_label}
                  </button>
                </div>
              </article>
            </div>
          </section>

          <section id="home-market-peek" class="al-panel al-home-market-peek" phx-hook="MissionMotion">
            <div class="al-home-market-head">
              <div>
                <p class="al-kicker">Live auctions</p>
                <h3>The market starts here and keeps moving.</h3>
                <p class="al-subcopy">
                  Watch active auctions from the home page, then open the full list when you are ready
                  to inspect price and place a bid.
                </p>
              </div>

              <div class="al-home-market-actions">
                <div class="al-launch-tags" aria-label="Auction counts">
                  <span class="al-launch-tag">Biddable {@biddable_count}</span>
                  <span class="al-launch-tag">Live {@live_count}</span>
                  <span class="al-launch-tag">Showing {length(@preview_tokens)}</span>
                </div>
                <.link navigate={~p"/auctions"} class="al-submit">Open all auctions</.link>
              </div>
            </div>

            <%= if @preview_tokens == [] do %>
              <.empty_state
                title="No auctions are live yet."
                body="The next launch will appear here as soon as the market opens."
                action_label="Open the guide"
                action_href={~p"/how-auctions-work"}
              />
            <% else %>
              <section class="al-token-grid al-home-token-grid">
                <article
                  :for={token <- @preview_tokens}
                  id={"home-auction-preview-#{token.id}"}
                  class="al-panel al-token-card"
                >
                  <div class="al-token-card-head">
                    <div>
                      <p class="al-kicker">{token.agent_id}</p>
                      <h3>{token.agent_name}</h3>
                      <p class="al-inline-note">{token.symbol} • {token.phase}</p>
                    </div>
                    <span class={["al-status-badge", if(token.phase == "biddable", do: "is-ready", else: "is-muted")]}>
                      {String.capitalize(token.phase)}
                    </span>
                  </div>

                  <div class="al-launch-tags">
                    <span class="al-launch-tag">Price {display_value(token.current_price_usdc, "USDC")}</span>
                    <span class="al-launch-tag">Market cap {display_value(token.implied_market_cap_usdc, "USDC")}</span>
                    <span class="al-launch-tag">Started {format_date(token.started_at)}</span>
                  </div>

                  <div class="al-note-grid al-token-card-facts">
                    <article class="al-note-card">
                      <span>Price source</span>
                      <strong>{humanize_price_source(token.price_source)}</strong>
                      <p>{directory_copy(token.phase)}</p>
                    </article>
                    <article class="al-note-card">
                      <span>Auction</span>
                      <strong>{LaunchComponents.time_left_label(token.ends_at)}</strong>
                      <p>Trust summary: {trust_summary(token.trust)}</p>
                    </article>
                  </div>

                  <div class="al-action-row">
                    <.link navigate={token.detail_url} class="al-submit">
                      {if token.phase == "biddable", do: "Open bid view", else: "Inspect launch"}
                    </.link>
                    <.link :if={token.subject_url} navigate={token.subject_url} class="al-ghost">
                      Open token detail
                    </.link>
                  </div>
                </article>
              </section>
            <% end %>
          </section>

          <section id="home-flow" class="al-panel al-home-flow" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">How this page works</p>
                <h3>Start here. Come back here when the market is moving.</h3>
              </div>
            </div>

            <div class="al-directory-facts-grid">
              <article :for={step <- @home_steps} class="al-directory-fact-card">
                <span>Step</span>
                <strong>{step.title}</strong>
                <p>{step.body}</p>
              </article>
            </div>
          </section>
        </div>

        <aside id="home-right-rail" class="al-home-rail">
          <section
            id="home-xmtp-room"
            class="al-panel al-xmtp-room al-home-xmtp-room"
            phx-hook="PrivyXmtpRoom"
            data-privy-app-id={@privy_app_id}
            data-pending-request-id={@xmtp_room.pending_signature_request_id}
            data-connected-wallet={@xmtp_room.connected_wallet}
            data-membership-state={@xmtp_room.membership_state}
            data-can-join={to_string(@xmtp_room.can_join?)}
            data-can-send={to_string(@xmtp_room.can_send?)}
          >
            <div class="al-xmtp-head">
              <div class="al-xmtp-copy">
                <p class="al-kicker">Live wire</p>
                <h2>Stay on the Autolaunch wire.</h2>
                <p class="al-subcopy">
                  Join the room, keep up with new activity, and stay close to the operators while the
                  market is moving.
                </p>
              </div>

              <div class="al-xmtp-badges">
                <span class="al-network-badge">XMTP group</span>
                <span class="al-network-badge">
                  {@xmtp_room.member_count}/{@xmtp_room.seat_count} private seats
                </span>
                <span class="al-network-badge">{length(@xmtp_room.messages)} recent</span>
              </div>
            </div>

            <div class="al-xmtp-layout">
              <div class="al-xmtp-feed" data-xmtp-feed>
                <%= if @xmtp_room.messages == [] do %>
                  <div class="al-xmtp-empty">
                    No public posts yet. Connect your wallet and send the first one.
                  </div>
                <% else %>
                  <%= for message <- @xmtp_room.messages do %>
                    <article
                      id={"xmtp-room-message-#{message.key}"}
                      class={["al-xmtp-bubble", message.side == :self && "is-self"]}
                      data-xmtp-entry
                      data-message-key={message.key}
                    >
                      <header>
                        <strong>{message.author}</strong>
                        <span>{message.stamp}</span>
                      </header>
                      <p>{message.body}</p>
                      <div :if={@xmtp_room.moderator?} class="al-xmtp-moderation">
                        <button
                          :if={message.can_delete?}
                          type="button"
                          class="al-ghost"
                          phx-click="xmtp_delete_message"
                          phx-value-message_id={message.key}
                        >
                          Delete on website
                        </button>
                        <button
                          :if={message.can_kick?}
                          type="button"
                          class="al-ghost"
                          phx-click="xmtp_kick_user"
                          phx-value-target={message.sender_wallet || message.sender_inbox_id}
                        >
                          Kick user
                        </button>
                      </div>
                    </article>
                  <% end %>
                <% end %>
              </div>

              <div class="al-xmtp-composer">
                <div class="al-xmtp-composer-head">
                  <button type="button" class="al-submit" data-xmtp-auth>
                    {if @current_human, do: "Disconnect wallet", else: "Connect wallet"}
                  </button>

                  <button
                    :if={@current_human}
                    type="button"
                    class="al-ghost"
                    data-xmtp-join
                    disabled={!@xmtp_room.can_join?}
                  >
                    Join room
                  </button>

                  <p class="al-inline-note" data-xmtp-state>{@xmtp_room.status}</p>
                </div>

                <label class="al-xmtp-input-wrap">
                  <span>Message</span>
                  <input
                    type="text"
                    maxlength="2000"
                    placeholder="Write to the Autolaunch wire"
                    data-xmtp-input
                    disabled={!@xmtp_room.can_send?}
                  />
                </label>

                <button type="button" class="al-submit" data-xmtp-send disabled={!@xmtp_room.can_send?}>
                  Send update
                </button>
              </div>
            </div>
          </section>
        </aside>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp reload_home(socket), do: assign_home_market(socket)

  defp assign_home_market(socket) do
    directory =
      launch_module().list_auctions(
        %{"mode" => "all", "sort" => "newest"},
        socket.assigns[:current_human]
      )

    preview_tokens =
      directory
      |> Enum.sort_by(fn token -> if token.phase == "biddable", do: 0, else: 1 end)
      |> Enum.take(4)

    socket
    |> assign(:preview_tokens, preview_tokens)
    |> assign(:biddable_count, Enum.count(directory, &(&1.phase == "biddable")))
    |> assign(:live_count, Enum.count(directory, &(&1.phase == "live")))
  end

  defp wizard_command, do: "regent autolaunch prelaunch wizard"

  defp wizard_transcript do
    """
    > regent autolaunch prelaunch validate --plan plan_alpha
    > regent autolaunch prelaunch publish --plan plan_alpha
    > regent autolaunch launch run --plan plan_alpha
    > regent autolaunch launch monitor --job job_alpha
    """
    |> String.trim()
  end

  defp display_value(nil, unit), do: "Unavailable #{unit}"
  defp display_value(value, unit), do: "#{value} #{unit}"

  defp format_date(nil), do: "Unknown"

  defp format_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d")
      _ -> "Unknown"
    end
  end

  defp humanize_price_source("auction_clearing"), do: "Auction clearing"
  defp humanize_price_source("uniswap_spot"), do: "Uniswap spot"
  defp humanize_price_source("uniswap_spot_unavailable"), do: "Quote pending"
  defp humanize_price_source(_), do: "Unavailable"

  defp trust_summary(%{ens: %{connected: true, name: name}, world: %{connected: true}})
       when is_binary(name),
       do: "#{name} • World connected"

  defp trust_summary(%{ens: %{connected: true, name: name}}) when is_binary(name), do: name
  defp trust_summary(%{world: %{connected: true, launch_count: count}}), do: "World #{count}"
  defp trust_summary(_), do: "Optional links"

  defp directory_copy("biddable"),
    do: "Still inside the active auction window."

  defp directory_copy("live"),
    do: "Now trading after the auction closed."

  defp load_xmtp_panel(current_human) do
    {:ok, panel} = Xmtp.public_room_panel(current_human)
    panel
  end

  defp xmtp_error_panel(assigns, :wallet_required) do
    Map.put(assigns.xmtp_room, :status, "Connect your wallet before joining the room.")
  end

  defp xmtp_error_panel(assigns, :message_required) do
    Map.put(assigns.xmtp_room, :status, "Write a message before sending.")
  end

  defp xmtp_error_panel(assigns, :message_too_long) do
    Map.put(assigns.xmtp_room, :status, "Messages must stay under 2,000 characters.")
  end

  defp xmtp_error_panel(assigns, :signature_request_missing) do
    Map.put(assigns.xmtp_room, :status, "The signature request expired. Click join again.")
  end

  defp xmtp_error_panel(assigns, :join_required) do
    Map.put(assigns.xmtp_room, :status, "Join the room before sending.")
  end

  defp xmtp_error_panel(assigns, :room_full) do
    Map.put(
      assigns.xmtp_room,
      :status,
      "The room is full right now. Watch from the feed until a seat opens."
    )
  end

  defp xmtp_error_panel(assigns, :kicked) do
    Map.put(
      assigns.xmtp_room,
      :status,
      "You were removed from the room. Click join again when ready."
    )
  end

  defp xmtp_error_panel(assigns, :moderator_required) do
    Map.put(assigns.xmtp_room, :status, "Only moderator wallets can manage the public mirror.")
  end

  defp xmtp_error_panel(assigns, :message_not_found) do
    Map.put(
      assigns.xmtp_room,
      :status,
      "That message is no longer available in the website mirror."
    )
  end

  defp xmtp_error_panel(assigns, :member_not_found) do
    Map.put(assigns.xmtp_room, :status, "That user is no longer inside the private room.")
  end

  defp xmtp_error_panel(assigns, _reason) do
    Map.put(assigns.xmtp_room, :status, "The room is unavailable right now.")
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:home_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
