defmodule Autolaunch.PublicIdentity do
  @moduledoc """
  Resolves the public label and picture for a signed human without exposing its
  private identity. Every wallet is public, and so is the ENS name that points to it.
  """

  @wallet ~r/\A0x[0-9a-fA-F]{40}\z/

  def label(identity) when is_map(identity) do
    identity
    |> preferred_labels()
    |> Enum.find_value(&present_label/1)
    |> case do
      nil ->
        case wallet(identity) do
          nil -> "Account"
          wallet -> RegentFormat.short_address(String.downcase(wallet))
        end

      label ->
        label
    end
  end

  def label(_identity), do: "Account"

  @doc """
  The name a list other people read prints for an account: its display name when
  that is the name it shows, else `nil` when it shows by its wallet, its ENS name
  or short address, which a page draws with `Regent.Primitives.address`. An account
  with neither a display name nor a wallet prints its `label/1`.
  """
  def listed_name(identity) do
    case present_label(Map.get(identity, :display_name)) do
      nil -> if !wallet(identity), do: label(identity)
      name -> name
    end
  end

  @doc "The account's wallet address, when it has one."
  def wallet(identity) do
    case Map.get(identity, :wallet_address) do
      wallet when is_binary(wallet) ->
        wallet = String.trim(wallet)
        if Regex.match?(@wallet, wallet), do: wallet

      _ ->
        nil
    end
  end

  @doc "The ENS name's picture, when it has one."
  def picture(identity), do: present_label(Map.get(identity, :ens_avatar_url))

  @doc "A picture generated from the account's wallet address."
  def squares(identity), do: identity |> wallet() |> wallet_avatar()

  @doc "The account's ENS name, if it has one and it is loaded."
  def ens_name(identity) when is_map(identity), do: present_label(Map.get(identity, :ens_name))
  def ens_name(_identity), do: nil

  # The ENS name's picture, else one generated from the wallet address.
  def avatar_src(identity) when is_map(identity), do: picture(identity) || squares(identity)

  def avatar_src(_identity), do: nil

  defp preferred_labels(identity) do
    [
      Map.get(identity, :display_name),
      Map.get(identity, :ens_name)
    ]
  end

  defp present_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      label -> label
    end
  end

  defp present_label(_label), do: nil

  defp wallet_avatar(nil), do: nil

  defp wallet_avatar(wallet) do
    digest = :crypto.hash(:sha256, String.downcase(wallet))
    bytes = :binary.bin_to_list(digest)
    [red, green, blue, red2, green2, blue2 | cells] = bytes

    primary = color(red, green, blue)
    secondary = color(red2, green2, blue2)

    marks =
      for row <- 0..4,
          column <- 0..2,
          value = Enum.at(cells, row * 3 + column),
          rem(value, 3) != 0,
          mirrored_column <- mirrored_columns(column) do
        fill = if rem(value, 3) == 1, do: primary, else: secondary
        ~s(<rect x="#{mirrored_column}" y="#{row}" width="1" height="1" fill="#{fill}"/>)
      end
      |> Enum.join()

    svg =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 5 5" shape-rendering="crispEdges"><rect width="5" height="5" fill="#121212"/>#{marks}</svg>)

    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  defp mirrored_columns(0), do: [0, 4]
  defp mirrored_columns(1), do: [1, 3]
  defp mirrored_columns(2), do: [2]

  defp color(red, green, blue) do
    "rgb(#{bright(red)},#{bright(green)},#{bright(blue)})"
  end

  defp bright(component), do: 72 + rem(component, 168)
end
