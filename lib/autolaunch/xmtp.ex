defmodule Autolaunch.Xmtp do
  @moduledoc false

  alias Autolaunch.Accounts.HumanUser
  alias Xmtp.Principal

  @manager __MODULE__.Manager

  def child_spec(opts \\ []) do
    Xmtp.child_spec(
      Keyword.merge(opts,
        name: @manager,
        repo: Autolaunch.Repo,
        pubsub: Autolaunch.PubSub,
        rooms: {:mfa, __MODULE__, :rooms, []}
      )
    )
  end

  def subscribe do
    Xmtp.subscribe(@manager, default_room_key())
  end

  def topic do
    Xmtp.topic(@manager, default_room_key())
  end

  def room_server(room_key \\ default_room_key()) do
    Xmtp.Manager.via(@manager, room_key)
  end

  def public_room_panel(current_human \\ nil, claims \\ %{}) do
    Xmtp.public_room_panel(
      @manager,
      default_room_key(),
      principal(current_human),
      claims
    )
  end

  def request_join(current_human, claims \\ %{}) do
    Xmtp.request_join(@manager, default_room_key(), principal(current_human), claims)
  end

  def complete_join_signature(current_human, request_id, signature, claims \\ %{}) do
    Xmtp.complete_join_signature(
      @manager,
      default_room_key(),
      principal(current_human),
      request_id,
      signature,
      claims
    )
  end

  def send_public_message(current_human, body) do
    Xmtp.send_public_message(
      @manager,
      default_room_key(),
      principal(current_human),
      body
    )
  end

  def invite_user(current_human_or_system, target_wallet_or_inbox) do
    Xmtp.invite_user(
      @manager,
      default_room_key(),
      actor(current_human_or_system),
      target_wallet_or_inbox
    )
  end

  def kick_user(current_human_or_system, target_wallet_or_inbox) do
    Xmtp.kick_user(
      @manager,
      default_room_key(),
      actor(current_human_or_system),
      target_wallet_or_inbox
    )
  end

  def moderator_delete_message(current_human, message_id) do
    Xmtp.moderator_delete_message(
      @manager,
      default_room_key(),
      principal(current_human),
      message_id
    )
  end

  def moderator_kick_user(current_human, target_wallet_or_inbox) do
    kick_user(current_human, target_wallet_or_inbox)
  end

  def heartbeat(current_human) do
    Xmtp.heartbeat(@manager, default_room_key(), principal(current_human))
  end

  def bootstrap_room!(opts \\ []) do
    room_key = Keyword.get(opts, :room_key, default_room_key())
    Xmtp.bootstrap_room!(@manager, room_key, opts)
  end

  def reset_for_test! do
    Xmtp.reset_for_test!(@manager, default_room_key())
  end

  def room_key, do: default_room_key()

  def rooms do
    :autolaunch
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(:rooms)
  end

  def default_room_key do
    rooms()
    |> List.first()
    |> Map.fetch!(:key)
  end

  defp principal(nil), do: nil

  defp principal(%HumanUser{} = human) do
    Principal.human(%{
      id: human.id,
      wallet_address: human.wallet_address,
      wallet_addresses: Map.get(human, :wallet_addresses, []),
      inbox_id: human.xmtp_inbox_id,
      display_name: human.display_name
    })
  end

  defp principal(%{} = current_human) do
    Principal.human(%{
      id: Map.get(current_human, :id) || Map.get(current_human, "id"),
      wallet_address:
        Map.get(current_human, :wallet_address) || Map.get(current_human, "wallet_address"),
      wallet_addresses:
        Map.get(current_human, :wallet_addresses) ||
          Map.get(current_human, "wallet_addresses", []),
      inbox_id: Map.get(current_human, :xmtp_inbox_id) || Map.get(current_human, "xmtp_inbox_id"),
      display_name:
        Map.get(current_human, :display_name) || Map.get(current_human, "display_name")
    })
  end

  defp principal(_current_human), do: nil

  defp actor(:system), do: :system
  defp actor(value), do: principal(value)
end
