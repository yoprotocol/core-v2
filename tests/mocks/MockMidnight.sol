// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBlueBuyCallback } from "src/interfaces/external/IBlueBuyCallback.sol";
import { IMorpho } from "src/interfaces/IMorpho.sol";
import { Market } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";

/// @notice Minimal Morpho Midnight stand-in: authorization and credit redemption only. Credit is
///         keyed by loan token instead of market id. Fork tests target the real deployment.
contract MockMidnight {
    using SafeERC20 for IERC20;

    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;
    mapping(address user => mapping(address loanToken => uint256)) public credit;

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external {
        require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender], "unauthorized");
        isAuthorized[onBehalf][authorized] = newIsAuthorized;
    }

    function setCredit(address user, address loanToken, uint256 units) external {
        credit[user][loanToken] = units;
    }

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external {
        require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender], "unauthorized");
        credit[onBehalf][market.loanToken] -= units;
        IERC20(market.loanToken).safeTransfer(receiver, units);
    }
}

/// @notice Minimal `SetterRatifier` stand-in with the real authorization rule.
contract MockSetterRatifier {
    address public immutable MIDNIGHT;

    mapping(address maker => mapping(bytes32 root => bool)) public isRootRatified;

    constructor(address midnight) {
        MIDNIGHT = midnight;
    }

    function setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external {
        require(maker == msg.sender || MockMidnight(MIDNIGHT).isAuthorized(maker, msg.sender), "unauthorized");
        isRootRatified[maker][root] = newIsRootRatified;
    }
}

/// @notice Minimal `BlueBuyCallback` stand-in: owner and Blue authorization only. Like the real
///         constructor, it authorizes `OWNER` on Blue.
contract MockBlueBuyCallback is IBlueBuyCallback {
    address public immutable OWNER;
    address public immutable BLUE;

    constructor(address owner, address blue) {
        OWNER = owner;
        BLUE = blue;
        IMorpho(blue).setAuthorization(owner, true);
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(msg.sender == OWNER, "not owner");
        IMorpho(BLUE).setAuthorization(authorized, newIsAuthorized);
    }
}

/// @notice Minimal `BlueBuyCallbackFactory` stand-in.
contract MockBlueBuyCallbackFactory {
    address public immutable MIDNIGHT;
    address public immutable BLUE;

    mapping(address callback => bool) public isBlueBuyCallback;

    constructor(address midnight, address blue) {
        MIDNIGHT = midnight;
        BLUE = blue;
    }

    function createBlueBuyCallback(address owner) external returns (address callback) {
        callback = address(new MockBlueBuyCallback(owner, BLUE));
        isBlueBuyCallback[callback] = true;
    }
}
