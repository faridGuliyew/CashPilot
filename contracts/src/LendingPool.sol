// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LendingPool
/// @notice Liquidity providers deposit mUSDC; the FinancingController draws advances from it and the
///         RepaymentEscrow returns principal + fee. Fees accrue to LPs through share value.
contract LendingPool is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_UTILIZATION_CAP_BPS = 9_000;

    IERC20 public immutable asset;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public totalOutstanding;
    uint256 public utilizationCapBps = MAX_UTILIZATION_CAP_BPS;

    error ZeroAmount();
    error InsufficientShares();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error UtilizationCapExceeded(uint256 outstandingAfter, uint256 limit);
    error InvalidCap();
    error RepaymentExceedsOutstanding();

    event Deposited(address indexed lp, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lp, uint256 amount, uint256 shares);
    event Disbursed(address indexed to, uint256 amount, uint256 totalOutstanding);
    event RepaymentReceived(uint256 principal, uint256 fee, uint256 totalOutstanding);
    event UtilizationCapSet(uint256 capBps);

    constructor(address admin, IERC20 asset_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        asset = asset_;
    }

    // ----------------------------------------------------------------- views

    /// @notice Idle cash plus money currently lent out.
    function totalAssets() public view returns (uint256) {
        return availableLiquidity() + totalOutstanding;
    }

    function availableLiquidity() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfAssets(address lp) external view returns (uint256) {
        return totalShares == 0 ? 0 : Math.mulDiv(sharesOf[lp], totalAssets(), totalShares);
    }

    function utilizationBps() external view returns (uint256) {
        uint256 ta = totalAssets();
        return ta == 0 ? 0 : (totalOutstanding * BPS) / ta;
    }

    // ----------------------------------------------------------------- LPs

    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        uint256 ta = totalAssets();
        shares = (totalShares == 0 || ta == 0) ? amount : Math.mulDiv(amount, totalShares, ta);
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        emit Deposited(msg.sender, amount, shares);
        asset.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw `amount` of mUSDC. Funds that are lent out cannot be withdrawn.
    function withdraw(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity(amount, available);
        shares = Math.mulDiv(amount, totalShares, totalAssets(), Math.Rounding.Ceil);
        if (shares > sharesOf[msg.sender]) revert InsufficientShares();
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        emit Withdrawn(msg.sender, amount, shares);
        asset.safeTransfer(msg.sender, amount);
    }

    // ----------------------------------------------------------------- protocol

    function disburse(address to, uint256 amount) external nonReentrant onlyRole(CONTROLLER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity(amount, available);
        uint256 outstandingAfter = totalOutstanding + amount;
        uint256 limit = (totalAssets() * utilizationCapBps) / BPS;
        if (outstandingAfter > limit) revert UtilizationCapExceeded(outstandingAfter, limit);
        totalOutstanding = outstandingAfter;
        emit Disbursed(to, amount, outstandingAfter);
        asset.safeTransfer(to, amount);
    }

    /// @notice Pulls principal + fee from the escrow and closes that much outstanding principal.
    function receiveRepayment(uint256 principal, uint256 fee) external nonReentrant onlyRole(ESCROW_ROLE) {
        if (principal > totalOutstanding) revert RepaymentExceedsOutstanding();
        totalOutstanding -= principal;
        emit RepaymentReceived(principal, fee, totalOutstanding);
        asset.safeTransferFrom(msg.sender, address(this), principal + fee);
    }

    // ----------------------------------------------------------------- admin

    function setUtilizationCap(uint256 capBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (capBps == 0 || capBps > MAX_UTILIZATION_CAP_BPS) revert InvalidCap();
        utilizationCapBps = capBps;
        emit UtilizationCapSet(capBps);
    }
}
