defmodule AutolaunchWeb.Api.PrelaunchControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  defmodule PrelaunchStub do
    def list_plans(_human) do
      {:ok, [%{plan_id: "plan_alpha", state: "draft"}]}
    end

    def create_plan(%{"agent_id" => "84532:42"} = params, _human) do
      {:ok,
       %{
         plan_id: "plan_alpha",
         state: "draft",
         agent_id: "84532:42",
         token_name: params["token_name"],
         metadata_draft: params["metadata_draft"] || %{}
       }}
    end

    def create_plan(_params, _human), do: {:error, :agent_not_found}

    def get_plan("plan_alpha", _human) do
      {:ok,
       %{
         plan_id: "plan_alpha",
         state: "validated",
         agent_id: "84532:42",
         validation_summary: %{"launchable" => false}
       }}
    end

    def get_plan(_plan_id, _human), do: {:error, :not_found}

    def update_plan("plan_alpha", params, _human) do
      {:ok,
       %{
         plan_id: "plan_alpha",
         state: "draft",
         token_name: params["token_name"] || "Atlas Coin",
         metadata_draft: %{"title" => "Atlas Launch"}
       }}
    end

    def update_plan(_plan_id, _params, _human), do: {:error, :not_found}

    def validate_plan("plan_alpha", _human) do
      {:ok,
       %{
         plan: %{
           plan_id: "plan_alpha",
           state: "launchable",
           validation_summary: %{"launchable" => true}
         },
         validation: %{
           "launchable" => true,
           "blockers" => [],
           "warnings" => []
         }
       }}
    end

    def validate_plan(_plan_id, _human), do: {:error, :not_found}

    def publish_plan("plan_alpha", _human) do
      {:ok,
       %{
         plan: %{plan_id: "plan_alpha", state: "launchable"},
         metadata_url: "/v1/app/prelaunch/plans/plan_alpha/metadata-preview"
       }}
    end

    def publish_plan(_plan_id, _human), do: {:error, :not_launchable}

    def launch_plan("plan_alpha", %{"wallet_address" => wallet}, _human, request_ip) do
      {:ok,
       %{
         plan: %{plan_id: "plan_alpha", state: "launched", launch_job_id: "job_alpha"},
         launch: %{job_id: "job_alpha", wallet_address: wallet, request_ip: request_ip}
       }}
    end

    def launch_plan(_plan_id, _params, _human, _request_ip), do: {:error, :not_launchable}

    def upload_asset(%{"source_url" => source_url}, _human) do
      {:ok,
       %{
         asset_id: "asset_alpha",
         file_name: "atlas.png",
         media_type: "text/uri-list",
         public_url: source_url
       }}
    end

    def upload_asset(%{"file_name" => file_name}, _human) do
      {:ok,
       %{
         asset_id: "asset_upload",
         file_name: file_name,
         media_type: "image/png",
         public_url: "/prelaunch-assets/asset_upload.png"
       }}
    end

    def update_metadata("plan_alpha", _params, _human) do
      {:ok,
       %{
         plan: %{plan_id: "plan_alpha", metadata_draft: %{"title" => "Atlas Launch"}},
         metadata_preview: %{
           title: "Atlas Launch",
           image_url: "/prelaunch-assets/asset_upload.png"
         }
       }}
    end

    def update_metadata(_plan_id, _params, _human), do: {:error, :not_found}

    def metadata_preview("plan_alpha", _human) do
      {:ok,
       %{
         plan_id: "plan_alpha",
         title: "Atlas Launch",
         description: "Hosted preview",
         image_url: "/prelaunch-assets/asset_upload.png"
       }}
    end

    def metadata_preview(_plan_id, _human), do: {:error, :not_found}
  end

  setup do
    original = Application.get_env(:autolaunch, :prelaunch_api, [])
    Application.put_env(:autolaunch, :prelaunch_api, context_module: PrelaunchStub)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_api, original) end)
    :ok
  end

  test "lists plans", %{conn: conn} do
    conn = get(conn, "/v1/app/prelaunch/plans")

    assert %{"ok" => true, "plans" => [%{"plan_id" => "plan_alpha", "state" => "draft"}]} =
             json_response(conn, 200)
  end

  test "creates and shows a plan", %{conn: conn} do
    create_conn =
      post(conn, "/v1/app/prelaunch/plans", %{
        "agent_id" => "84532:42",
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS",
        "agent_safe_address" => "0x1111111111111111111111111111111111111111",
        "metadata_draft" => %{"title" => "Atlas Launch"}
      })

    assert %{"ok" => true, "plan" => %{"plan_id" => "plan_alpha"}} =
             json_response(create_conn, 200)

    show_conn = get(conn, "/v1/app/prelaunch/plans/plan_alpha")

    assert %{"ok" => true, "plan" => %{"plan_id" => "plan_alpha", "state" => "validated"}} =
             json_response(show_conn, 200)
  end

  test "validates, publishes, and launches a plan", %{conn: conn} do
    validate_conn = post(conn, "/v1/app/prelaunch/plans/plan_alpha/validate", %{})

    assert %{
             "ok" => true,
             "validation" => %{"launchable" => true, "warnings" => []}
           } = json_response(validate_conn, 200)

    publish_conn = post(conn, "/v1/app/prelaunch/plans/plan_alpha/publish", %{})

    assert %{
             "ok" => true,
             "metadata_url" => "/v1/app/prelaunch/plans/plan_alpha/metadata-preview"
           } = json_response(publish_conn, 200)

    launch_conn =
      post(conn, "/v1/app/prelaunch/plans/plan_alpha/launch", %{
        "wallet_address" => "0x00000000000000000000000000000000000000aa",
        "nonce" => "nonce_123",
        "message" => "sign me",
        "signature" => "0xsig",
        "issued_at" => "2026-03-27T00:00:00Z"
      })

    assert %{
             "ok" => true,
             "launch" => %{
               "job_id" => "job_alpha",
               "wallet_address" => "0x00000000000000000000000000000000000000aa"
             }
           } = json_response(launch_conn, 200)
  end

  test "launch ignores spoofed forwarded headers when recording the request ip", %{conn: conn} do
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 11})
      |> put_req_header("x-forwarded-for", "198.51.100.88")

    launch_conn =
      post(conn, "/v1/app/prelaunch/plans/plan_alpha/launch", %{
        "wallet_address" => "0x00000000000000000000000000000000000000aa",
        "nonce" => "nonce_123",
        "message" => "sign me",
        "signature" => "0xsig",
        "issued_at" => "2026-03-27T00:00:00Z"
      })

    assert %{
             "ok" => true,
             "launch" => %{"request_ip" => "203.0.113.11"}
           } = json_response(launch_conn, 200)
  end

  test "uploads assets and updates metadata preview", %{conn: conn} do
    upload_conn =
      post(conn, "/v1/app/prelaunch/assets", %{
        "file_name" => "atlas.png",
        "media_type" => "image/png",
        "content_base64" => Base.encode64("atlas")
      })

    assert %{"ok" => true, "asset" => %{"asset_id" => "asset_upload"}} =
             json_response(upload_conn, 200)

    metadata_conn =
      post(conn, "/v1/app/prelaunch/plans/plan_alpha/metadata", %{
        "metadata" => %{
          "title" => "Atlas Launch",
          "image_url" => "/prelaunch-assets/asset_upload.png"
        }
      })

    assert %{
             "ok" => true,
             "metadata_preview" => %{
               "title" => "Atlas Launch",
               "image_url" => "/prelaunch-assets/asset_upload.png"
             }
           } = json_response(metadata_conn, 200)

    preview_conn = get(conn, "/v1/app/prelaunch/plans/plan_alpha/metadata-preview")

    assert %{
             "ok" => true,
             "metadata_preview" => %{"title" => "Atlas Launch"}
           } = json_response(preview_conn, 200)
  end
end
