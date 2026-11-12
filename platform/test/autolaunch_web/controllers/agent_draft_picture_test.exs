defmodule AutolaunchWeb.AgentDraftPictureTest do
  @moduledoc """
  A paired agent's signed draft save carries the draft's picture, so its body
  may be as large as a 2 MB picture in base64 beside the draft's text. Every
  other signed route keeps the 16 KB body. The sign-in service is stubbed: it
  vouches for the wallet a request names when the request carries the fixture
  proof. Each test calls from its own address, so it spends its own budget.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.LaunchDraft.ImageValidator
  alias Autolaunch.TestSupport

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"headers" => headers} = Jason.decode!(body)
      wallet = headers["x-agent-wallet-address"]

      Req.Test.json(conn, %{
        code: "http_envelope_valid",
        data: %{
          verified: true,
          walletAddress: wallet,
          agentBook: nil,
          agentRegistration: nil,
          principal: %{
            kind: "wallet",
            wallet_address: wallet,
            chain_id: 8453,
            audience: "autolaunch"
          }
        }
      })
    end)

    %{
      from: {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)},
      agent: paired_wallet()
    }
  end

  test "a draft save takes a picture of the full 2 MB, and refuses a larger one by name",
       %{from: from, agent: agent} do
    for kind <- ["revstake", "memestock"] do
      saved = save(kind, picture(ImageValidator.maximum_bytes()), from, agent)
      assert %{"data" => %{"name" => "Picture", "image" => image}} = json_response(saved, 200)
      assert is_binary(image)
    end

    larger = save("memestock", picture(ImageValidator.maximum_bytes() + 1), from, agent)
    assert %{"error" => %{"code" => "image_too_large"}} = json_response(larger, 422)
  end

  test "a body past the picture's room is refused as too large, and other signed routes keep 16 KB",
       %{from: from, agent: agent} do
    for {method, path, bytes} <- [
          {:patch, "/api/agent/v1/drafts/revstake", 3_000_000},
          {:patch, "/api/agent/v1/drafts/other", 20_000},
          {:post, "/api/agents/v1/check-in", 20_000},
          {:post, "/mcp", 20_000}
        ] do
      body = Jason.encode!(%{"name" => String.duplicate("a", bytes)})

      {413, _headers, answer} =
        assert_error_sent(413, fn -> signed(method, path, body, from, agent) end)

      assert %{"error" => %{"code" => _}} = Jason.decode!(answer)
    end
  end

  defp save(kind, bytes, from, agent) do
    body =
      Jason.encode!(%{
        "name" => "Picture",
        "image" => %{"content_type" => "image/jpeg", "data" => Base.encode64(bytes)}
      })

    signed(:patch, "/api/agent/v1/drafts/#{kind}", body, from, agent)
  end

  defp signed(method, path, body, from, agent) do
    conn(method, path, body)
    |> Map.put(:remote_ip, from)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> put_req_header("x-agent-wallet-address", agent)
    |> @endpoint.call([])
  end

  # The fixture picture, made exactly `size` bytes by comment segments after
  # its start marker; it stays a complete JPEG.
  defp picture(size) do
    <<255, 216, rest::binary>> = File.read!("test/support/fixtures/launch-draft.jpg")
    <<255, 216, comments(size - byte_size(rest) - 2)::binary, rest::binary>>
  end

  defp comments(0), do: <<>>

  defp comments(bytes) do
    segment = min(bytes, 65_537)

    <<255, 0xFE, segment - 2::16, 0::size(segment - 4)-unit(8),
      comments(bytes - segment)::binary>>
  end

  # An agent's wallet, paired with a person's account here.
  defp paired_wallet do
    account = TestSupport.register_creator!()
    agent = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Agent", :codex,
      actor: %RegentAgents.Agent{wallet: agent}
    )

    agent
  end
end
