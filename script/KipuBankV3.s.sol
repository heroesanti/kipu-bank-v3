// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract KipuBankV3Script is Script {
    // Mainnet addresses (replace with testnet addresses for local testing)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        // Load deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Set bank cap to 1,000,000 USDC (6 decimals)
        uint256 bankCap = 1_000_000 * 10 ** 6;

        // Deploy KipuBankV3
        KipuBankV3 kipuBank = new KipuBankV3(
            bankCap,
            CHAINLINK_ETH_USD,
            UNIVERSAL_ROUTER,
            PERMIT2
        );

        // Optionally, create an account for deployer
        kipuBank.createAccount();

        vm.stopBroadcast();
    }
}
