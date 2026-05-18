defmodule Autolaunch.CCAMarketTest do
  use ExUnit.Case, async: true

  alias Autolaunch.CCA.Abi
  alias Autolaunch.CCA.Market
  alias Autolaunch.Contracts.ActionParams

  test "submit bid request carries REGENT amount in calldata with zero native value" do
    auction = %{
      chain_id: 8_453,
      auction_address: "0x0000000000000000000000000000000000000011",
      auction_quote_token_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07"
    }

    owner_address = "0x00000000000000000000000000000000000000aa"
    amount_raw = 1_000_000_000_000_000_000
    max_price_q96 = 237_684_487_542_793_012_780_631_851_008

    assert {:ok, request} =
             Market.build_submit_tx_request(auction, owner_address, amount_raw, max_price_q96)

    assert request.value_hex == "0x0"
    assert request.to == auction.auction_address
    assert String.starts_with?(request.data, Abi.selector(:submit_bid_simple))
    assert request.data =~ String.pad_leading(Integer.to_string(amount_raw, 16), 64, "0")

    assert request.approval == %{
             token: auction.auction_quote_token_address,
             spender: auction.auction_address,
             amount: Integer.to_string(amount_raw),
             data: Abi.encode_approve(auction.auction_address, amount_raw)
           }

    assert {:ok, prepared} =
             ActionParams.prepare_tx_request(request, "auction", "submit_bid", %{},
               expected_signer: owner_address
             )

    assert prepared.approval == request.approval
    assert prepared.wallet_action.approval == request.approval
  end
end
