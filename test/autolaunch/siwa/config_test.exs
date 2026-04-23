defmodule Autolaunch.Siwa.ConfigTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Siwa.Config

  setup do
    original_siwa_cfg = Application.get_env(:autolaunch, :siwa, [])

    on_exit(fn ->
      Application.put_env(:autolaunch, :siwa, original_siwa_cfg)
    end)

    :ok
  end

  test "fetch_http_config uses explicit defaults when timeouts are omitted" do
    Application.put_env(:autolaunch, :siwa, internal_url: " http://siwa.test ")

    assert {:ok,
            %{
              internal_url: "http://siwa.test",
              connect_timeout_ms: 2_000,
              receive_timeout_ms: 5_000
            }} = Config.fetch_http_config()
  end

  test "fetch_http_config accepts positive timeout values" do
    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://siwa.test",
      http_connect_timeout_ms: "3000",
      http_receive_timeout_ms: 7_000
    )

    assert {:ok,
            %{
              connect_timeout_ms: 3_000,
              receive_timeout_ms: 7_000
            }} = Config.fetch_http_config()
  end

  test "fetch_http_config rejects invalid timeout values" do
    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://siwa.test",
      http_connect_timeout_ms: "invalid",
      http_receive_timeout_ms: 5_000
    )

    assert {:error, {:invalid_siwa_timeout, :http_connect_timeout_ms}} =
             Config.fetch_http_config()

    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://siwa.test",
      http_connect_timeout_ms: 2_000,
      http_receive_timeout_ms: 0
    )

    assert {:error, {:invalid_siwa_timeout, :http_receive_timeout_ms}} =
             Config.fetch_http_config()
  end
end
