// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVault is IERC4626 {
    function process_report(address _strategy) external returns (uint256, uint256);
}
