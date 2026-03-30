defmodule AutolaunchWeb.Api.ContractsControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  defmodule ContractsStub do
    def admin_overview do
      {:ok,
       %{
         admin_contracts: %{
           revenue_share_factory: %{address: "0x1111111111111111111111111111111111111111"}
         }
       }}
    end

    def job_state("job_contracts", _human) do
      {:ok,
       %{
         job: %{
           job_id: "job_contracts",
           token_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
         },
         strategy: %{address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
       }}
    end

    def job_state(_job_id, _human), do: {:error, :not_found}

    def subject_state(subject_id, _human) do
      {:ok,
       %{
         subject: %{
           subject_id: String.downcase(subject_id),
           splitter_address: "0x9999999999999999999999999999999999999999"
         },
         registry: %{address: "0x2222222222222222222222222222222222222222"}
       }}
    end

    def prepare_job_action("job_contracts", "strategy", "migrate", _attrs, _human) do
      {:ok,
       %{
         job_id: "job_contracts",
         prepared: %{
           resource: "strategy",
           action: "migrate",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             value: "0x0",
             data: "0x8fd3ab80"
           }
         }
       }}
    end

    def prepare_job_action("job_invalid_address", _resource, _action, _attrs, _human),
      do: {:error, :invalid_address}

    def prepare_job_action(_job_id, _resource, _action, _attrs, _human),
      do: {:error, :unsupported_action}

    def prepare_subject_action(
          "subject_forbidden",
          _resource,
          _action,
          _attrs,
          _human
        ),
        do: {:error, :forbidden}

    def prepare_subject_action(
          subject_id,
          "splitter",
          "set_paused",
          %{"paused" => "true"},
          _human
        ) do
      {:ok,
       %{
         subject_id: String.downcase(subject_id),
         prepared: %{
           resource: "splitter",
           action: "set_paused",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0x9999999999999999999999999999999999999999",
             value: "0x0",
             data: "0x16c38b3c"
           }
         }
       }}
    end

    def prepare_subject_action(_subject_id, _resource, _action, _attrs, _human),
      do: {:error, :unsupported_action}

    def prepare_admin_action("revenue_share_factory", "set_authorized_creator", _attrs) do
      {:ok,
       %{
         prepared: %{
           resource: "revenue_share_factory",
           action: "set_authorized_creator",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0x1111111111111111111111111111111111111111",
             value: "0x0",
             data: "0xe1434f4e"
           }
         }
       }}
    end

    def prepare_admin_action("broken", "set_authorized_creator", _attrs),
      do: {:error, :invalid_uint}

    def prepare_admin_action(_resource, _action, _attrs), do: {:error, :unsupported_action}
  end

  setup do
    original = Application.get_env(:autolaunch, :contracts_api, [])
    Application.put_env(:autolaunch, :contracts_api, context_module: ContractsStub)
    on_exit(fn -> Application.put_env(:autolaunch, :contracts_api, original) end)
    :ok
  end

  test "admin route returns configured contract surface", %{conn: conn} do
    conn = get(conn, "/api/contracts/admin")

    assert %{
             "ok" => true,
             "admin_contracts" => %{"revenue_share_factory" => %{"address" => address}}
           } =
             json_response(conn, 200)

    assert address == "0x1111111111111111111111111111111111111111"
  end

  test "job route returns launch contract stack state", %{conn: conn} do
    conn = get(conn, "/api/contracts/jobs/job_contracts")

    assert %{
             "ok" => true,
             "job" => %{"job_id" => "job_contracts"},
             "strategy" => %{"address" => strategy}
           } =
             json_response(conn, 200)

    assert strategy == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  end

  test "job prepare route returns prepared transaction payload", %{conn: conn} do
    conn = post(conn, "/api/contracts/jobs/job_contracts/strategy/migrate/prepare", %{})

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "strategy",
               "action" => "migrate",
               "tx_request" => %{"data" => "0x8fd3ab80"}
             }
           } = json_response(conn, 200)
  end

  test "subject prepare route returns prepared transaction payload", %{conn: conn} do
    conn =
      post(
        conn,
        "/api/contracts/subjects/0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/splitter/set_paused/prepare",
        %{"paused" => "true"}
      )

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "splitter",
               "action" => "set_paused",
               "tx_request" => %{"data" => "0x16c38b3c"}
             }
           } = json_response(conn, 200)
  end

  test "prepare routes translate stable contract errors", %{conn: conn} do
    invalid_address_conn =
      post(conn, "/api/contracts/jobs/job_invalid_address/strategy/migrate/prepare", %{})

    assert %{
             "error" => %{
               "code" => "invalid_address",
               "message" => "Address is invalid"
             }
           } = json_response(invalid_address_conn, 422)

    forbidden_conn =
      post(
        conn,
        "/api/contracts/subjects/subject_forbidden/splitter/set_paused/prepare",
        %{"paused" => "true"}
      )

    assert %{
             "error" => %{
               "code" => "contract_scope_forbidden",
               "message" => "Contract action is not allowed"
             }
           } = json_response(forbidden_conn, 403)

    invalid_uint_conn =
      post(conn, "/api/contracts/admin/broken/set_authorized_creator/prepare", %{})

    assert %{
             "error" => %{
               "code" => "invalid_amount",
               "message" => "Amount must be a whole onchain unit"
             }
           } = json_response(invalid_uint_conn, 422)
  end
end
