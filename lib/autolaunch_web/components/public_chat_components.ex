defmodule AutolaunchWeb.PublicChatComponents do
  @moduledoc false

  use AutolaunchWeb, :html

  alias AutolaunchWeb.Format

  attr :room, :map, required: true
  attr :form, :map, required: true

  def public_chat_panel(assigns) do
    ~H"""
    <aside
      id="autolaunch-public-room"
      class="al-panel al-home-chat-panel"
      phx-hook="AutolaunchXmtpRoom"
    >
      <div class="al-home-chat-head">
        <div>
          <p class="al-kicker">Community room</p>
          <h3>Read the launch room.</h3>
          <p>Watch the room from the homepage. Join when you want to post.</p>
        </div>
        <div class="al-home-chat-badges">
          <span>{room_state_label(@room)}</span>
          <span>{Integer.to_string(@room.member_count)}/{Integer.to_string(@room.capacity)} seats</span>
          <span>{active_member_copy(@room)}</span>
          <span :if={@room.connected_wallet}>{Format.short_wallet(@room.connected_wallet)}</span>
        </div>
      </div>

      <div class="al-home-chat-feed" data-public-chat-feed>
        <%= if @room.messages == [] do %>
          <div class="al-home-chat-empty">
            <strong>No messages yet.</strong>
            <p>Join the room, then post the first question or update.</p>
          </div>
        <% else %>
          <article
            :for={message <- @room.messages}
            id={"public-chat-message-#{message_key(message)}"}
            class={["al-home-chat-message", own_message?(message, @room) && "is-self"]}
            data-public-chat-entry
            data-message-key={message_key(message)}
          >
            <div class="al-home-chat-message-meta">
              <span>{sender_label(message_sender_type(message))}</span>
              <span class={message_author_class(message)}>{message_author(message)}</span>
              <span>{message_stamp(message)}</span>
            </div>
            <p>{message_body(message)}</p>
          </article>
        <% end %>
      </div>

      <div class="al-home-chat-status" data-public-chat-status>
        {room_status_copy(@room)}
      </div>

      <button
        :if={@room.can_join}
        type="button"
        class="al-home-chat-join"
        phx-click="public_chat_join"
      >
        Join room
      </button>

      <.form for={@form} id="public-chat-form" phx-submit="public_chat_send" class="al-home-chat-form">
        <label for={@form[:body].id}>Post a message</label>
        <textarea
          id={@form[:body].id}
          name={@form[:body].name}
          rows="3"
          placeholder="Ask a question or share an update."
          disabled={!@room.can_send}
        >{Phoenix.HTML.Form.input_value(@form, :body)}</textarea>

        <div class="al-home-chat-composer-row">
          <p>{composer_copy(@room)}</p>
          <button type="submit" disabled={!@room.can_send}>Send</button>
        </div>
      </.form>
    </aside>
    """
  end

  defp room_status_copy(%{user_copy: %{primary: message}}) when is_binary(message), do: message

  defp room_status_copy(%{status: :disabled}), do: "This room is unavailable right now."
  defp room_status_copy(%{membership: :joined}), do: "You are in the room."

  defp room_status_copy(%{membership: :pending_signature}),
    do: "Your room seat is being prepared."

  defp room_status_copy(%{membership: :not_joined, can_join: false, connected_wallet: wallet})
       when is_binary(wallet),
       do: "Sign in with your wallet before you join this room."

  defp room_status_copy(%{membership: :not_joined, seats_remaining: seats_remaining})
       when seats_remaining > 0,
       do: "#{seats_remaining} seats are open. Join when you are ready."

  defp room_status_copy(%{seats_remaining: 0}),
    do: "All seats are filled right now. You can still read along from this page."

  defp room_status_copy(_room), do: "Read along before you join. Post once you are in."

  defp room_state_label(%{status: :disabled}), do: "Offline"
  defp room_state_label(%{membership: :joined}), do: "In room"
  defp room_state_label(%{membership: :pending_signature}), do: "Joining"
  defp room_state_label(%{membership: :blocked}), do: "Full"
  defp room_state_label(%{membership: :removed}), do: "Removed"
  defp room_state_label(%{connected_wallet: nil}), do: "Watch only"
  defp room_state_label(_room), do: "Ready"

  defp active_member_copy(%{active_member_count: 1}), do: "1 active"

  defp active_member_copy(%{active_member_count: count}) when is_integer(count),
    do: "#{count} active"

  defp active_member_copy(_room), do: "0 active"

  defp sender_label(:agent), do: "Agent"
  defp sender_label(:system), do: "System"
  defp sender_label(_kind), do: "Person"

  defp composer_copy(%{can_send: true}),
    do: "Keep messages short so the room stays easy to follow."

  defp composer_copy(%{can_join: true}), do: "Join the room first if you want to post."

  defp composer_copy(%{membership: :pending_signature}),
    do: "Wait for your seat to finish opening before posting."

  defp composer_copy(%{membership: :removed}),
    do: "Posting is paused for this wallet."

  defp composer_copy(%{seats_remaining: 0}), do: "Posting is closed while the room is full."
  defp composer_copy(_room), do: "Read along here even if you are not ready to post."

  defp message_key(message), do: Map.get(message, :id) || Map.get(message, :xmtp_message_id)

  defp own_message?(message, %{connected_wallet: wallet}) when is_binary(wallet) do
    message
    |> Map.get(:sender_wallet_address)
    |> normalize_wallet() == normalize_wallet(wallet)
  end

  defp own_message?(_message, _room), do: false

  defp message_sender_type(message), do: Map.get(message, :sender_type) || :human

  defp message_author(message) do
    author = message |> Map.get(:author) |> present_string()
    sender_label = message |> Map.get(:sender_label) |> present_string()
    sender_wallet = message |> Map.get(:sender_wallet_address) |> present_string()

    cond do
      not is_nil(author) -> author
      not is_nil(sender_label) -> sender_label
      not is_nil(sender_wallet) -> Format.short_wallet(sender_wallet)
      true -> "Room member"
    end
  end

  defp message_author_class(%{author_tone: :animata_holder}), do: "al-home-chat-author-holder"
  defp message_author_class(_message), do: nil

  defp message_stamp(message) do
    case Map.get(message, :sent_at) do
      %DateTime{} = sent_at -> Calendar.strftime(sent_at, "%b %-d, %-I:%M %p UTC")
      value when is_binary(value) -> Format.display_datetime(value)
      _ -> "Now"
    end
  end

  defp message_body(message), do: Map.get(message, :body) || ""

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp normalize_wallet(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_wallet(_value), do: nil
end
