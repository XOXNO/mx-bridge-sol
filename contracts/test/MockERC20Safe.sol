// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IERC20Safe.sol";

contract MockERC20Safe is IERC20Safe {
    address public override admin;
    bool public override paused;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenMinLimits;
    mapping(address => uint256) public override tokenMaxLimits;

    // Track deposits for verification
    uint256 public depositCount;
    uint256 public scDepositCount;

    struct DepositRecord {
        address token;
        uint256 amount;
        bytes32 recipient;
        bytes callData;
    }

    DepositRecord[] public deposits;
    DepositRecord[] public scDeposits;

    constructor(address _admin) {
        admin = _admin;
        paused = false;
    }

    function setAdmin(address _admin) external {
        admin = _admin;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function whitelistToken(address token, uint256 minLimit, uint256 maxLimit) external {
        whitelistedTokens[token] = true;
        tokenMinLimits[token] = minLimit;
        tokenMaxLimits[token] = maxLimit;
    }

    function setTokenLimits(address token, uint256 minLimit, uint256 maxLimit) external {
        tokenMinLimits[token] = minLimit;
        tokenMaxLimits[token] = maxLimit;
    }

    /// @notice Toggle whitelist state for a token (test-only).
    function setWhitelisted(address token, bool ok) external {
        whitelistedTokens[token] = ok;
    }

    function deposit(address tokenAddress, uint256 amount, bytes32 recipientAddress) external override {
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
        deposits.push(DepositRecord({token: tokenAddress, amount: amount, recipient: recipientAddress, callData: ""}));
        depositCount++;
    }

    function depositWithSCExecution(
        address tokenAddress,
        uint256 amount,
        bytes32 recipientAddress,
        bytes calldata callData
    ) external override {
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
        scDeposits.push(
            DepositRecord({token: tokenAddress, amount: amount, recipient: recipientAddress, callData: callData})
        );
        scDepositCount++;
    }

    function getDeposit(uint256 index) external view returns (DepositRecord memory) {
        return deposits[index];
    }

    function getSCDeposit(uint256 index) external view returns (DepositRecord memory) {
        return scDeposits[index];
    }
}
