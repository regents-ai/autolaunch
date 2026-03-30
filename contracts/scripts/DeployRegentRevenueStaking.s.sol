// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";

contract DeployRegentRevenueStakingScript is Script {
    struct ScriptConfig {
        address regentToken;
        address usdc;
        address treasuryRecipient;
        uint16 stakerShareBps;
        address owner;
    }

    function deployFromEnv() external returns (RegentRevenueStaking staking) {
        return deploy(loadConfigFromEnv());
    }

    function deploy(ScriptConfig memory cfg) public returns (RegentRevenueStaking staking) {
        vm.startBroadcast();
        staking = new RegentRevenueStaking(
            cfg.regentToken, cfg.usdc, cfg.treasuryRecipient, cfg.stakerShareBps, cfg.owner
        );
        vm.stopBroadcast();
    }

    function loadConfigFromEnv() public view returns (ScriptConfig memory cfg) {
        cfg.regentToken = vm.envAddress("BASE_REGENT_TOKEN_ADDRESS");
        require(cfg.regentToken != address(0), "REGENT_TOKEN_ZERO");

        cfg.usdc = vm.envAddress("BASE_USDC_ADDRESS");
        require(cfg.usdc != address(0), "USDC_ZERO");

        cfg.treasuryRecipient = vm.envAddress("REGENT_REVENUE_TREASURY_ADDRESS");
        require(cfg.treasuryRecipient != address(0), "TREASURY_ZERO");

        cfg.owner = vm.envAddress("REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS");
        require(cfg.owner != address(0), "OWNER_ZERO");

        cfg.stakerShareBps = uint16(vm.envUint("REGENT_REVENUE_STAKER_SHARE_BPS"));
        require(cfg.stakerShareBps <= 10_000, "STAKER_SHARE_BPS_INVALID");
    }

    function run() external {
        ScriptConfig memory cfg = loadConfigFromEnv();
        RegentRevenueStaking staking = deploy(cfg);

        console2.log(
            string.concat(
                "REGENT_REVENUE_STAKING_RESULT_JSON:{\"contractAddress\":\"",
                vm.toString(address(staking)),
                "\",\"regentTokenAddress\":\"",
                vm.toString(cfg.regentToken),
                "\",\"usdcAddress\":\"",
                vm.toString(cfg.usdc),
                "\",\"treasuryRecipient\":\"",
                vm.toString(cfg.treasuryRecipient),
                "\",\"owner\":\"",
                vm.toString(cfg.owner),
                "\",\"stakerShareBps\":",
                vm.toString(uint256(cfg.stakerShareBps)),
                "}"
            )
        );
    }
}
