defmodule AutolaunchWeb.CreateLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.ImageFetch
  alias Autolaunch.LaunchDraftImageStorage
  alias Autolaunch.TestSupport

  @live_draft %{
    "name" => "Open Research",
    "symbol" => "open",
    "description" => "A launch profile awaiting review.",
    "website" => "https://example.test/open",
    "treasury" => "0xAbCdeF0000000000000000000000000000000001",
    "required_regent_raised" => "1000.5"
  }

  test "Create sends an anonymous visitor home", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/create")
  end

  test "a signed-in Human sees one continuous launch form", %{conn: conn} do
    account = draft_account!("autolaunch-stages")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    refute has_element?(view, ~s(nav[aria-label="Launch stages"]))
    refute has_element?(view, ~s([phx-click="select_launch_stage"]))
    refute has_element?(view, "#autolaunch-create", "Form your Regent")
    refute has_element?(view, "#autolaunch-create", "Open Formation")
    refute has_element?(view, "#autolaunch-create", "This part of Regent isn't open yet")
    assert has_element?(view, "#launch-token-details")
    assert has_element?(view, "#launch-token-details", "Recommended: 400 × 400 px")
    assert has_element?(view, "#launch-image-url", "Paste an image link")
    assert has_element?(view, "#launch-treasury-details")
    assert has_element?(view, "#autolaunch-create", "Create a 2-of-3 Safe on Base")
    assert has_element?(view, "#launch-transactions button[disabled]", "Complete token details")
    assert has_element?(view, ~s(aside[aria-label="Live launch preview"]), "Your auction")
    assert has_element?(view, "#autolaunch-create-x-connections-profile", "Profile X")
    assert has_element?(view, "#autolaunch-create-x-connections-company", "Company X")
  end

  test "partial token, treasury, and EOA warning input survives remounts and stays account-private",
       %{conn: conn} do
    account = draft_account!("autolaunch-autosave")
    actor = %Human{human_account_id: account.id}
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    {:ok, view, _html} = live(signed_in, "/create")

    view
    |> form("#launch-token-details",
      launch_draft: %{
        "name" => "Open Research",
        "symbol" => "",
        "description" => "Still writing",
        "website" => "draft link",
        "required_regent_raised" => "1."
      }
    )
    |> render_change()

    view
    |> form("#launch-treasury-details",
      launch_draft: %{
        "treasury" => "0x123",
        "treasury_path" => "eoa",
        "eoa_acknowledgement" => "I am still typing"
      }
    )
    |> render_change()

    assert {:ok, [persisted]} = Autolaunch.list_my_launch_drafts(actor: actor)
    assert persisted.name == "Open Research"
    assert persisted.symbol == ""
    assert persisted.treasury == "0x123"
    assert persisted.eoa_acknowledgement == "I am still typing"

    {:ok, restored, _html} = live(signed_in, "/create")
    assert has_element?(restored, ~s(#launch-token-details-name[value="Open Research"]))
    assert has_element?(restored, "#launch-token-details-description", "Still writing")
    assert has_element?(restored, ~s(#launch-treasury-details-treasury[value="0x123"]))

    assert has_element?(
             restored,
             "#launch-treasury-details-eoa-acknowledgement",
             "I am still typing"
           )

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/create")

    other = draft_account!("autolaunch-autosave-other")

    {:ok, other_view, _html} =
      conn
      |> init_test_session(%{human_account_id: other.id})
      |> live("/create")

    refute has_element?(other_view, ~s(#launch-token-details-name[value="Open Research"]))
  end

  test "an overlong EOA acknowledgement is marked and explained beside the textarea", %{
    conn: conn
  } do
    account = draft_account!("autolaunch-eoa-error")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    view
    |> form("#launch-treasury-details",
      launch_draft: %{
        "treasury" => "0x3333333333333333333333333333333333333337",
        "treasury_path" => "eoa",
        "eoa_acknowledgement" => String.duplicate("x", 513)
      }
    )
    |> render_change()

    id = "launch-treasury-details-eoa-acknowledgement"

    assert has_element?(
             view,
             "##{id}[aria-invalid=true][aria-describedby~='#{id}-warning'][aria-describedby~='#{id}-error']"
           )

    assert has_element?(view, "##{id}-error[role=alert]")
  end

  test "image upload plus complete token and treasury stages unlocks the wallet mount", %{
    conn: conn
  } do
    {:ok, auctions_before} = Autolaunch.list_auctions()
    {:ok, tokens_before} = Autolaunch.list_tokens()
    {:ok, launches_before} = Autolaunch.list_launches()

    account = draft_account!("autolaunch-complete")
    actor = %Human{human_account_id: account.id}

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    view
    |> form("#launch-token-details", launch_draft: Map.drop(@live_draft, ["treasury"]))
    |> render_change()

    upload =
      file_input(view, "#launch-token-details", :launch_image, [
        %{name: "token.png", content: png(), type: "image/png"}
      ])

    render_upload(upload, "token.png")
    assert has_element?(view, "[role=status]", "Image saved to your account.")

    view
    |> form("#launch-treasury-details",
      launch_draft: %{"treasury" => @live_draft["treasury"], "treasury_path" => "safe"}
    )
    |> render_change()

    assert {:ok, [draft]} = Autolaunch.list_my_launch_drafts(actor: actor)
    assert Autolaunch.LaunchDraft.launch_ready?(draft)

    html = render(view)
    assert html =~ ~s(id="launch-transactions")
    assert html =~ "Launch transactions"
    assert html =~ "Ready"
    assert has_element?(view, "#autolaunch-launch-wallet-#{draft.id}")
    refute has_element?(view, "[data-launch-wallet-send]")

    assert {:ok, auctions_after} = Autolaunch.list_auctions()
    assert {:ok, tokens_after} = Autolaunch.list_tokens()
    assert {:ok, launches_after} = Autolaunch.list_launches()
    assert Enum.map(auctions_after, & &1.id) == Enum.map(auctions_before, & &1.id)
    assert Enum.map(tokens_after, & &1.id) == Enum.map(tokens_before, & &1.id)
    assert Enum.map(launches_after, & &1.job_id) == Enum.map(launches_before, & &1.job_id)
  end

  test "a second distinct image is refused without changing the first saved image", %{conn: conn} do
    account = draft_account!("autolaunch-one-image")
    actor = %Human{human_account_id: account.id}

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    first =
      file_input(view, "#launch-token-details", :launch_image, [
        %{name: "first.png", content: png(), type: "image/png"}
      ])

    render_upload(first, "first.png")
    assert {:ok, draft} = Autolaunch.get_my_account_launch_draft(actor: actor)
    assert {:ok, saved} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)

    repeat =
      file_input(view, "#launch-token-details", :launch_image, [
        %{name: "same.png", content: png(), type: "image/png"}
      ])

    render_upload(repeat, "same.png")
    assert {:ok, same} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert same.id == saved.id

    different =
      file_input(view, "#launch-token-details", :launch_image, [
        %{name: "different.jpg", content: jpeg(), type: "image/jpeg"}
      ])

    render_upload(different, "different.jpg")

    assert has_element?(
             view,
             "[role=alert]",
             "This launch already has its image."
           )

    assert {:ok, still_saved} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert still_saved.id == saved.id
    assert {:ok, still_draft} = Autolaunch.get_my_account_launch_draft(actor: actor)
    assert still_draft.image == LaunchDraftImageStorage.public_url(saved)
  end

  test "a pasted public image link stores the image and shows it in the preview", %{conn: conn} do
    previous = Application.get_env(:autolaunch, ImageFetch, [])
    Application.put_env(:autolaunch, ImageFetch, plug: png_plug())
    on_exit(fn -> restore_image_fetch_env(previous) end)

    account = draft_account!("autolaunch-fetch-ok")
    actor = %Human{human_account_id: account.id}

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    view
    |> form("#launch-image-url", %{"url" => "http://8.8.8.8/token.png"})
    |> render_submit()

    await_image_notice(view, "Image saved to your account.")
    assert has_element?(view, ~s(img[alt="Saved token image"]))

    assert {:ok, draft} = Autolaunch.get_my_account_launch_draft(actor: actor)
    assert {:ok, image} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert draft.image == LaunchDraftImageStorage.public_url(image)
    assert has_element?(view, ~s(img[src="#{draft.image}"]))
  end

  test "a pasted private or invalid image link leaves the draft without an image", %{conn: conn} do
    previous = Application.get_env(:autolaunch, ImageFetch, [])
    on_exit(fn -> restore_image_fetch_env(previous) end)

    account = draft_account!("autolaunch-fetch-fail")
    actor = %Human{human_account_id: account.id}

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    Application.put_env(:autolaunch, ImageFetch, [])

    view
    |> form("#launch-image-url", %{"url" => "http://127.0.0.1/x.png"})
    |> render_submit()

    await_image_notice(
      view,
      "That link points somewhere we can't reach from the internet. Try a public image link."
    )

    assert {:ok, draft} = Autolaunch.get_my_account_launch_draft(actor: actor)
    assert is_nil(draft.image)
    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)

    Application.put_env(:autolaunch, ImageFetch, plug: invalid_plug())

    view
    |> form("#launch-image-url", %{"url" => "http://8.8.8.8/x.png"})
    |> render_submit()

    await_image_notice(view, "That link did not give us a PNG, JPEG, or WebP image.")

    assert {:ok, still} = Autolaunch.get_my_account_launch_draft(actor: actor)
    assert is_nil(still.image)
    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(still.id, actor: actor)
  end

  test "Create explains the one-auction limit and keeps the draft editable", %{conn: conn} do
    account = draft_account!("autolaunch-limit")
    TestSupport.project_auction(title: "Already launched", creator_human_account_id: account.id)

    {:ok, view, html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/create")

    assert html =~ "You already have an auction. One auction per account for now."
    assert has_element?(view, "#launch-token-details")
    assert has_element?(view, "#launch-treasury-details")

    view
    |> form("#launch-token-details", launch_draft: %{"name" => "Still mine"})
    |> render_change()

    assert has_element?(view, ~s(#launch-token-details-name[value="Still mine"]))
    assert has_element?(view, "[role=status]", "Saved to your account.")
  end

  defp draft_account!(suffix) do
    wallet = "0x" <> String.pad_leading("#{Elixir.System.unique_integer([:positive])}", 40, "0")

    Accounts.register_verified!(
      "did:privy:create-live:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end

  defp png, do: File.read!("test/support/fixtures/launch-draft.png")
  defp jpeg, do: File.read!("test/support/fixtures/launch-draft.jpg")

  defp png_plug do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, png())
    end
  end

  defp invalid_plug do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, "not-an-image")
    end
  end

  defp await_image_notice(view, copy, attempts \\ 50)

  defp await_image_notice(view, copy, attempts) when attempts > 0 do
    render_async(view, 200)

    if has_element?(view, "[role=alert]", copy) or has_element?(view, "[role=status]", copy) do
      render(view)
    else
      Process.sleep(10)
      await_image_notice(view, copy, attempts - 1)
    end
  end

  defp await_image_notice(_view, copy, 0), do: flunk("missing image notice: #{copy}")

  defp restore_image_fetch_env([]), do: Application.delete_env(:autolaunch, ImageFetch)

  defp restore_image_fetch_env(previous),
    do: Application.put_env(:autolaunch, ImageFetch, previous)
end
