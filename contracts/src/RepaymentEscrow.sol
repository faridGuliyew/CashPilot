// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InvoiceRegistry} from "./InvoiceRegistry.sol";
import {InvoiceNFT} from "./InvoiceNFT.sol";
import {LendingPool} from "./LendingPool.sol";
import {FinancingController} from "./FinancingController.sol";

/// @title RepaymentEscrow
/// @notice The buyer pays the invoice face value here. A financed invoice repays the pool first
///         (advance + fee) and the remainder goes to the seller. No oracle is needed: the loan
///         closes when the payment lands.
contract RepaymentEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    InvoiceRegistry public immutable registry;
    InvoiceNFT public immutable nft;
    LendingPool public immutable pool;
    FinancingController public immutable controller;

    error NotBuyer();
    error NotPayable(uint256 invoiceId, InvoiceRegistry.Status status);

    event InvoicePaid(
        uint256 indexed invoiceId, address indexed buyer, uint256 faceValue, uint256 toPool, uint256 toSeller
    );

    constructor(
        IERC20 asset_,
        InvoiceRegistry registry_,
        InvoiceNFT nft_,
        LendingPool pool_,
        FinancingController controller_
    ) {
        asset = asset_;
        registry = registry_;
        nft = nft_;
        pool = pool_;
        controller = controller_;
    }

    function pay(uint256 invoiceId) external nonReentrant {
        InvoiceRegistry.Invoice memory inv = registry.getInvoice(invoiceId);
        if (msg.sender != inv.buyer) revert NotBuyer();
        InvoiceRegistry.Status s = inv.status;
        bool financed = s == InvoiceRegistry.Status.Financed || s == InvoiceRegistry.Status.Defaulted;
        if (!financed && s != InvoiceRegistry.Status.Confirmed) revert NotPayable(invoiceId, s);

        uint256 toPool = 0;
        uint256 principal = 0;
        uint256 fee = 0;
        if (financed) {
            FinancingController.Financing memory f = controller.financingOf(invoiceId);
            principal = f.advanceAmount;
            fee = f.feeAmount;
            toPool = principal + fee;
        }
        uint256 toSeller = inv.faceValue - toPool;

        emit InvoicePaid(invoiceId, msg.sender, inv.faceValue, toPool, toSeller);

        // state transitions in trusted protocol contracts, then token movements
        registry.setRepaid(invoiceId);
        nft.burn(invoiceId);

        // interactions
        asset.safeTransferFrom(msg.sender, address(this), inv.faceValue);
        if (toPool > 0) {
            asset.forceApprove(address(pool), toPool);
            pool.receiveRepayment(principal, fee);
        }
        if (toSeller > 0) asset.safeTransfer(inv.seller, toSeller);
    }
}
