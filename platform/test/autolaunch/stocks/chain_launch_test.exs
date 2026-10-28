defmodule Autolaunch.Stocks.ChainLaunchTest do
  @moduledoc """
  A launch made outside the site carries text, a website and a picture no
  create page checked. Whatever it carries, the site keeps only what a page
  can show safely: text with nothing hidden in it, a full https:// website,
  and a picture this site stores.
  """

  use Autolaunch.DataCase, async: true
  use ExUnitProperties

  alias Autolaunch.LaunchLinks
  alias Autolaunch.Stocks.ChainLaunch

  # Control characters other than a line break, and the marks that reorder text.
  @hidden ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  # Any bytes at all, and text built from the characters that hide or reorder it.
  defp carried do
    one_of([
      binary(max_length: 80),
      string(:printable, max_length: 80),
      map(
        list_of(
          one_of([
            string(:alphanumeric, max_length: 6),
            member_of(["\u202E", "\u2066", "\u200F", "\u0000", "\u0007", "\n", " ", "\u009B"])
          ]),
          max_length: 12
        ),
        &Enum.join/1
      )
    ])
  end

  # CHAIN_LAUNCH_SHOWS_ONLY_WHAT_PASSES: for every value a launch can carry.
  property "CHAIN_LAUNCH_SHOWS_ONLY_WHAT_PASSES: text, website and picture are kept only as a page may show them" do
    check all(value <- carried(), max_runs: 300) do
      case ChainLaunch.text(value) do
        nil ->
          :ok

        text ->
          assert String.valid?(text)
          refute text =~ @hidden
          assert text == String.trim(text)
          assert text != ""
      end

      case ChainLaunch.website(value) do
        nil -> :ok
        link -> assert LaunchLinks.web_link?(link)
      end

      assert ChainLaunch.image(value) == nil
    end
  end

  test "a picture is kept only when this site stores it, at this site's address" do
    account =
      Autolaunch.Accounts.register_verified!(
        "did:privy:chain-launch-#{System.unique_integer([:positive])}",
        "0x1414141414141414141414141414141414141414",
        ["0x1414141414141414141414141414141414141414"],
        actor: %Autolaunch.Actors.System{}
      )

    actor = %Autolaunch.Actors.Human{human_account_id: account.id}
    draft = Autolaunch.create_stocks_launch_draft!(%{}, actor: actor)
    png = File.read!("test/support/fixtures/launch-draft.png")

    {:ok, %{draft: %{image: stored}}} =
      Autolaunch.Stocks.LaunchDraftImageStorage.store_and_attach(
        draft,
        png,
        "image/png",
        "launch.png",
        actor
      )

    assert ChainLaunch.image(stored) == stored

    %URI{path: path} = URI.parse(stored)
    assert ChainLaunch.image("https://elsewhere.example" <> path) == nil

    assert ChainLaunch.image(
             AutolaunchWeb.Endpoint.url() <>
               "/stock-images/#{Ecto.UUID.generate()}/#{String.duplicate("a", 64)}"
           ) == nil

    assert ChainLaunch.image("https://elsewhere.example/picture.png") == nil
  end
end
