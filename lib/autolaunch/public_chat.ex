defmodule Autolaunch.PublicChat do
  @moduledoc false

  alias Autolaunch.Accounts.HumanUser

  @type join_result ::
          {:ok, map()}
          | {:needs_signature, map()}
          | {:error, atom()}

  @spec subscribe() :: :ok
  def subscribe, do: xmtp_module().subscribe()

  @spec topic() :: String.t()
  def topic, do: xmtp_module().topic()

  @spec room_panel(HumanUser.t() | nil) :: map()
  def room_panel(current_human \\ nil) do
    case xmtp_module().public_room_panel(current_human) do
      {:ok, panel} -> panel
      {:error, reason} -> unavailable_panel(reason, current_human)
    end
  end

  @spec request_join(HumanUser.t() | nil) :: join_result()
  def request_join(nil), do: {:error, :wallet_required}

  def request_join(%HumanUser{} = current_human) do
    with :ok <- require_room_identity(current_human) do
      normalize_join_result(xmtp_module().request_join(current_human))
    end
  end

  @spec complete_join_signature(HumanUser.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def complete_join_signature(nil, _request_id, _signature), do: {:error, :wallet_required}

  def complete_join_signature(%HumanUser{} = current_human, request_id, signature) do
    with :ok <- require_room_identity(current_human) do
      case xmtp_module().complete_join_signature(current_human, request_id, signature) do
        {:ok, panel} -> {:ok, panel}
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    end
  end

  @spec send_message(HumanUser.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def send_message(nil, _body), do: {:error, :wallet_required}

  def send_message(%HumanUser{} = current_human, body) do
    with :ok <- require_room_identity(current_human) do
      case xmtp_module().send_public_message(current_human, body) do
        {:ok, panel} -> {:ok, panel}
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    end
  end

  @spec heartbeat(HumanUser.t() | nil) :: :ok
  def heartbeat(nil), do: :ok

  def heartbeat(%HumanUser{} = current_human) do
    if room_identity_ready?(current_human), do: xmtp_module().heartbeat(current_human)
    :ok
  end

  @spec reason_message(atom()) :: String.t()
  def reason_message(:wallet_required), do: "Sign in with your wallet before you join this room."

  def reason_message(:xmtp_identity_required),
    do: "Finish signing in before you join this room."

  def reason_message(:room_unavailable), do: "This room is unavailable right now."
  def reason_message(:room_not_found), do: "This room is unavailable right now."
  def reason_message(:room_full), do: "All seats are filled right now. You can still read along."
  def reason_message(:join_required), do: "Join the room before you post."
  def reason_message(:kicked), do: "This wallet was removed from the room."
  def reason_message(:join_not_allowed), do: "This wallet cannot join the room right now."
  def reason_message(:message_required), do: "Write a message before you send it."

  def reason_message(:message_too_long),
    do: "Keep the message shorter so the room stays readable."

  def reason_message(:signature_request_missing),
    do: "Start joining again before you approve the request."

  def reason_message(_reason), do: "This room is unavailable right now."

  defp normalize_join_result({:ok, panel}), do: {:ok, panel}

  defp normalize_join_result({:needs_signature, %{panel: panel} = request}) do
    {:needs_signature, Map.put(request, :panel, panel)}
  end

  defp normalize_join_result({:error, reason}), do: {:error, normalize_error(reason)}

  defp require_room_identity(%HumanUser{} = human) do
    if room_identity_ready?(human), do: :ok, else: {:error, :xmtp_identity_required}
  end

  defp room_identity_ready?(%HumanUser{xmtp_inbox_id: inbox_id})
       when is_binary(inbox_id) do
    String.trim(inbox_id) != ""
  end

  defp room_identity_ready?(_human), do: false

  defp unavailable_panel(reason, current_human) do
    config = room_config()

    %{
      room_key: config.key,
      room_name: config.name,
      room_id: nil,
      connected_wallet: connected_wallet(current_human),
      ready?: false,
      joined?: false,
      can_join?: false,
      can_send?: false,
      moderator?: false,
      membership_state: :view_only,
      status: reason_message(normalize_error(reason)),
      pending_signature_request_id: nil,
      member_count: 0,
      active_member_count: 0,
      seat_count: config.capacity,
      seats_remaining: config.capacity,
      messages: []
    }
  end

  defp connected_wallet(%HumanUser{wallet_address: wallet}) when is_binary(wallet), do: wallet
  defp connected_wallet(_current_human), do: nil

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :room_unavailable

  defp room_config do
    :autolaunch
    |> Application.get_env(Autolaunch.Xmtp, [])
    |> Keyword.fetch!(:rooms)
    |> List.first()
  end

  defp xmtp_module do
    :autolaunch
    |> Application.get_env(:public_chat, [])
    |> Keyword.get(:xmtp_module, Autolaunch.Xmtp)
  end
end
