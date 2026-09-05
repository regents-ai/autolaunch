defmodule AutolaunchWeb.RegentLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.BaseRpcStub, as: Stub
  alias Autolaunch.Chain.Abi

  @name "0x06fdde03"
  @symbol "0x95d89b41"
  @decimals "0x313ce567"
  @total_supply "0x18160ddd"
  @stake_token "0x51ed6a30"
  @total_staked "0x817b1cd2"
  @wei_million 1_000_000 * Integer.pow(10, 18)
  @wei_quarter 250_000 * Integer.pow(10, 18)

  test "renders the loading state then the facts", %{conn: conn} do
    Stub.install(:wallet_http_client, &happy_calls/2)

    {:ok, view, html} = live(conn, ~p"/regent")

    # The first render always carries the loading state; the live view may
    # already hold the facts by the time a query reaches it.
    assert html =~ "Reading the token."
    assert has_element?(view, "#regent-stake", "Stake REGENT")
    assert has_element?(view, "#regent-redeem", "Redeem")

    render_async(view)

    refute has_element?(view, "#regent-loading")
    assert has_element?(view, "#regent-name", "Regent")
    assert has_element?(view, "#regent-symbol", "REGENT")
    assert has_element?(view, "#regent-address", Abi.regent_address())
    assert has_element?(view, "#regent-decimals", "18")
    assert has_element?(view, "#regent-total-supply", "1M REGENT")
    assert has_element?(view, "#regent-total-staked", "250000 REGENT")
    assert has_element?(view, "#regent-block", "Read at block 32")
    assert has_element?(view, "main", "Every Autolaunch auction is quoted in REGENT.")
    assert has_element?(view, "#regent-stake", "Stake REGENT")
    assert has_element?(view, "#regent-redeem", "Redeem")
  end

  test "renders the failure copy with links when the read fails", %{conn: conn} do
    previous = Application.get_env(:autolaunch, :wallet_http_client)
    Application.put_env(:autolaunch, :wallet_http_client, Stub.Timeout)
    on_exit(fn -> restore(:wallet_http_client, previous) end)

    {:ok, view, _html} = live(conn, ~p"/regent")
    render_async(view)

    assert has_element?(
             view,
             "#regent-unavailable",
             "REGENT facts are unavailable right now."
           )

    refute has_element?(view, "#regent-facts")
    assert has_element?(view, "#regent-stake", "Stake REGENT")
    assert has_element?(view, "#regent-redeem", "Redeem")
    assert has_element?(view, "main", "Every Autolaunch auction is quoted in REGENT.")
  end

  defp happy_calls(data, _state) do
    case data do
      @name -> abi_string("Regent")
      @symbol -> abi_string("REGENT")
      @decimals -> Stub.uint(18)
      @total_supply -> Stub.uint(@wei_million)
      @stake_token -> "0x" <> Stub.address_word(Abi.regent_address())
      @total_staked -> Stub.uint(@wei_quarter)
    end
  end

  defp abi_string(text) do
    length = byte_size(text)
    pad = rem(32 - rem(length, 32), 32)
    padded = text <> :binary.copy(<<0>>, pad)

    "0x" <> Stub.hex_word(32) <> Stub.hex_word(length) <> Base.encode16(padded, case: :lower)
  end

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
