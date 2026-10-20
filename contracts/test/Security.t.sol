// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {InvoiceNFT} from "../src/InvoiceNFT.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {FinancingController} from "../src/FinancingController.sol";
import {RepaymentEscrow} from "../src/RepaymentEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Security properties. Test names are referenced in docs/SECURITY_SELF_ASSESSMENT.md.
contract SecurityTest is BaseTest {
    // ----------------------------------------------------------------- invoice integrity

    function test_RevertWhen_DuplicateInvoiceHash() public {
        bytes32 h = _invoiceHash("DUP-1", FACE, dueDate);
        vm.prank(agent);
        registry.registerInvoice(h, owner, buyerA, FACE, dueDate);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.DuplicateInvoice.selector, h));
        registry.registerInvoice(h, owner, buyerA, FACE, dueDate);

        // Also blocked for the seller directly and for a different buyer address
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.DuplicateInvoice.selector, h));
        registry.registerInvoice(h, owner, buyerB, FACE, dueDate);
    }

    function test_RevertWhen_NonBuyerConfirms() public {
        uint256 id = _register(FACE);
        vm.prank(owner);
        vm.expectRevert(InvoiceRegistry.NotBuyer.selector);
        registry.confirmByBuyer(id);
        vm.prank(agent);
        vm.expectRevert(InvoiceRegistry.NotBuyer.selector);
        registry.confirmByBuyer(id);
    }

    function test_RevertWhen_InvalidBuyerSignature() public {
        uint256 id = _register(FACE);
        // Signed by the seller instead of the buyer
        (, uint256 ownerKey) = makeAddrAndKey("owner-key");
        bytes memory wrongSigner = _signConfirmation(ownerKey, id);
        vm.expectRevert(InvoiceRegistry.InvalidBuyerSignature.selector);
        registry.confirmByBuyerWithSig(id, wrongSigner);
        // Garbage bytes
        vm.expectRevert(InvoiceRegistry.InvalidBuyerSignature.selector);
        registry.confirmByBuyerWithSig(id, hex"deadbeef");
        // Valid buyer signature for a different invoice
        uint256 other = _register(FACE);
        bytes memory sigForOther = _signConfirmation(buyerAKey, other);
        vm.expectRevert(InvoiceRegistry.InvalidBuyerSignature.selector);
        registry.confirmByBuyerWithSig(id, sigForOther);
    }

    function test_RevertWhen_UnauthorizedRegistration() public {
        bytes32 h = _invoiceHash("X-1", FACE, dueDate);
        // Random address
        vm.prank(stranger);
        vm.expectRevert(InvoiceRegistry.NotAuthorizedToRegister.selector);
        registry.registerInvoice(h, owner, buyerA, FACE, dueDate);
        // Agent after the seller revoked its authorization
        vm.prank(owner);
        registry.setAuthorizedAgent(agent, false);
        vm.prank(agent);
        vm.expectRevert(InvoiceRegistry.NotAuthorizedToRegister.selector);
        registry.registerInvoice(h, owner, buyerA, FACE, dueDate);
        // Authorized address without PROPOSER_ROLE
        vm.prank(owner);
        registry.setAuthorizedAgent(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(InvoiceRegistry.NotAuthorizedToRegister.selector);
        registry.registerInvoice(h, owner, buyerA, FACE, dueDate);
    }

    function test_RevertWhen_InvalidInvoiceData() public {
        vm.startPrank(owner);
        vm.expectRevert(InvoiceRegistry.InvalidInvoice.selector);
        registry.registerInvoice(bytes32(0), owner, buyerA, FACE, dueDate);
        vm.expectRevert(InvoiceRegistry.InvalidInvoice.selector);
        registry.registerInvoice(keccak256("a"), owner, owner, FACE, dueDate); // self-dealing
        vm.expectRevert(InvoiceRegistry.InvalidInvoice.selector);
        registry.registerInvoice(keccak256("b"), owner, buyerA, 0, dueDate);
        vm.expectRevert(InvoiceRegistry.InvalidInvoice.selector);
        registry.registerInvoice(keccak256("c"), owner, buyerA, FACE, uint64(block.timestamp));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- proposal limits (T2)

    function test_RevertWhen_ProposeOnUnconfirmedInvoice() public {
        uint256 id = _register(FACE);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.InvoiceNotConfirmed.selector, id));
        controller.propose(id, ADVANCE, FEE);
    }

    function test_RevertWhen_AdvanceAbove80Percent() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 tooMuch = ADVANCE + 1; // 80% + 1 unit
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.AdvanceAboveMaxRate.selector, tooMuch, ADVANCE));
        controller.propose(id, tooMuch, FEE);
        // 100% (what the prompt-injected memo asks for) is also rejected
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.AdvanceAboveMaxRate.selector, FACE, ADVANCE));
        controller.propose(id, FACE, FEE);
    }

    function test_RevertWhen_AdvanceAbovePerInvoiceCap() public {
        uint256 face = 20_000 * USDC; // 80% = 16,000 > cap 10,000
        uint256 id = _registerAndConfirm(face);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingController.AdvanceAbovePerInvoiceCap.selector, 10_001 * USDC, PER_INVOICE_CAP
            )
        );
        controller.propose(id, 10_001 * USDC, FEE);
    }

    function test_RevertWhen_FeeAbove5Percent() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 maxFee = (FACE * 500) / 10_000;
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.FeeAboveMax.selector, maxFee + 1, maxFee));
        controller.propose(id, ADVANCE, maxFee + 1);
    }

    function test_RevertWhen_ZeroAdvance() public {
        uint256 id = _registerAndConfirm(FACE);
        vm.prank(agent);
        vm.expectRevert(FinancingController.ZeroAdvance.selector);
        controller.propose(id, 0, 0);
    }

    function test_RevertWhen_NonProposerProposes() public {
        uint256 id = _registerAndConfirm(FACE);
        bytes32 role = controller.PROPOSER_ROLE();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, role)
        );
        controller.propose(id, ADVANCE, FEE);
    }

    // ----------------------------------------------------------------- approval (T3)

    function test_RevertWhen_AgentCallsApprove() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.prank(agent);
        vm.expectRevert(FinancingController.AgentCannotApprove.selector);
        controller.approve(pid);

        // Even when the agent registers itself as the seller, it cannot approve its own proposal.
        bytes32 h = _invoiceHash("AGENT-SELF", FACE, dueDate);
        vm.prank(agent);
        uint256 selfId = registry.registerInvoice(h, agent, buyerA, FACE, dueDate);
        vm.prank(buyerA);
        registry.confirmByBuyer(selfId);
        uint256 selfPid = _propose(selfId, ADVANCE, FEE);
        vm.prank(agent);
        vm.expectRevert(FinancingController.AgentCannotApprove.selector);
        controller.approve(selfPid);

        assertEq(usdc.balanceOf(agent), 0);
        assertEq(pool.totalOutstanding(), 0);
    }

    function test_RevertWhen_NonSellerApproves() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.prank(stranger);
        vm.expectRevert(FinancingController.NotInvoiceSeller.selector);
        controller.approve(pid);
        vm.prank(buyerA);
        vm.expectRevert(FinancingController.NotInvoiceSeller.selector);
        controller.approve(pid);
        vm.prank(admin);
        vm.expectRevert(FinancingController.NotInvoiceSeller.selector);
        controller.approve(pid);
    }

    function test_RevertWhen_NonSellerRejects() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.prank(stranger);
        vm.expectRevert(FinancingController.NotInvoiceSeller.selector);
        controller.reject(pid);
    }

    function test_RevertWhen_ProposalExpired() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.ProposalExpired.selector, pid));
        controller.approve(pid);
    }

    function test_RevertWhen_ProposalReused() public {
        (, uint256 pid) = _financed();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.ProposalNotPending.selector, pid));
        controller.approve(pid);
        assertEq(usdc.balanceOf(owner), ADVANCE); // paid exactly once
    }

    function test_RevertWhen_SecondProposalForFinancedInvoice() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid1 = _propose(id, ADVANCE, FEE);
        uint256 pid2 = _propose(id, ADVANCE, FEE);
        vm.prank(owner);
        controller.approve(pid1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.InvoiceNotConfirmed.selector, id));
        controller.approve(pid2);
    }

    function test_RevertWhen_DailyCapExceeded() public {
        uint256 face = 12_500 * USDC;
        uint256 advance = 10_000 * USDC; // 80%, at the per-invoice cap
        for (uint256 i = 0; i < 2; i++) {
            uint256 id = _registerAndConfirm(face);
            uint256 pid = _propose(id, advance, 0);
            vm.prank(owner);
            controller.approve(pid);
        }
        uint256 id3 = _registerAndConfirm(face);
        uint256 pid3 = _propose(id3, advance, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.DailyCapExceeded.selector, 30_000 * USDC, DAILY_CAP));
        controller.approve(pid3);

        // Next day the cap resets
        vm.warp(block.timestamp + 1 days);
        uint256 pid4 = _propose(id3, advance, 0);
        vm.prank(owner);
        controller.approve(pid4);
        assertEq(usdc.balanceOf(owner), 30_000 * USDC);
    }

    function test_RevertWhen_PoolUtilizationCapExceeded() public {
        vm.prank(lp);
        pool.withdraw(70_000 * USDC); // pool now holds 10,000 -> 90% cap = 9,000
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE); // 9,600
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.UtilizationCapExceeded.selector, ADVANCE, 9_000 * USDC)
        );
        controller.approve(pid);
    }

    function test_RevertWhen_PoolLacksLiquidity() public {
        vm.prank(lp);
        pool.withdraw(75_000 * USDC); // 5,000 left
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, ADVANCE, 5_000 * USDC));
        controller.approve(pid);
    }

    // ----------------------------------------------------------------- token / pool

    function test_RevertWhen_NFTTransferAttempted() public {
        uint256 id = _registerAndConfirm(FACE);
        vm.startPrank(owner);
        vm.expectRevert(InvoiceNFT.NonTransferable.selector);
        nft.transferFrom(owner, stranger, id);
        vm.expectRevert(InvoiceNFT.NonTransferable.selector);
        nft.safeTransferFrom(owner, stranger, id);
        // Seller cannot push it into the pool themselves either (only via an approved proposal)
        vm.expectRevert(InvoiceNFT.NonTransferable.selector);
        nft.transferFrom(owner, address(pool), id);
        vm.stopPrank();

        // Agent cannot use the controller-only path
        bytes32 role = nft.CONTROLLER_ROLE();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, role));
        nft.lockToPool(id);
    }

    function test_RevertWhen_NFTMintOrBurnByOutsider() public {
        bytes32 minter = nft.MINTER_ROLE();
        bytes32 burner = nft.BURNER_ROLE();
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, minter));
        nft.mint(agent, 999);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, burner));
        nft.burn(1);
        vm.stopPrank();
    }

    function test_RevertWhen_LPWithdrawsLentFunds() public {
        _financed();
        uint256 available = POOL_DEPOSIT - ADVANCE;
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, POOL_DEPOSIT, available));
        pool.withdraw(POOL_DEPOSIT);
        // Idle part is still withdrawable
        vm.prank(lp);
        pool.withdraw(available);
        assertEq(pool.availableLiquidity(), 0);
        assertEq(pool.totalOutstanding(), ADVANCE);
    }

    function test_RevertWhen_WithdrawMoreThanOwnShares() public {
        vm.prank(stranger);
        vm.expectRevert(LendingPool.InsufficientShares.selector);
        pool.withdraw(1 * USDC);
    }

    function test_RevertWhen_ZeroDepositOrWithdraw() public {
        vm.startPrank(lp);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.deposit(0);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdraw(0);
        vm.stopPrank();
    }

    function test_RevertWhen_OutsiderMovesPoolFunds() public {
        bytes32 cRole = pool.CONTROLLER_ROLE();
        bytes32 eRole = pool.ESCROW_ROLE();
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, cRole));
        pool.disburse(agent, 1 * USDC);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, eRole));
        pool.receiveRepayment(0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_OutsiderChangesInvoiceStatus() public {
        uint256 id = _registerAndConfirm(FACE);
        bytes32 cRole = registry.CONTROLLER_ROLE();
        bytes32 eRole = registry.ESCROW_ROLE();
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, cRole));
        registry.setFinanced(id);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, eRole));
        registry.setRepaid(id);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- admin (T4)

    function test_RevertWhen_Paused() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.prank(admin);
        controller.pause();

        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        controller.propose(id, ADVANCE, FEE);
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        controller.approve(pid);

        // Buyer can still repay while paused (no funds stuck)
        vm.prank(buyerA);
        escrow.pay(id);
        assertEq(usdc.balanceOf(owner), FACE);
    }

    function test_RevertWhen_AgentChangesLimits() public {
        bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
        vm.startPrank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole)
        );
        controller.setLimits(type(uint256).max, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole)
        );
        controller.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole)
        );
        controller.unpause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole)
        );
        controller.grantRole(adminRole, agent);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole)
        );
        pool.setUtilizationCap(9_000);
        vm.stopPrank();
        assertEq(controller.perInvoiceCap(), PER_INVOICE_CAP);
    }

    function test_RevertWhen_OutsiderMintsUSDC() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        usdc.mint(agent, 1);
    }

    function test_UtilizationCapBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(LendingPool.InvalidCap.selector);
        pool.setUtilizationCap(9_001);
        vm.expectRevert(LendingPool.InvalidCap.selector);
        pool.setUtilizationCap(0);
        pool.setUtilizationCap(5_000);
        vm.stopPrank();
        assertEq(pool.utilizationCapBps(), 5_000);
    }

    function test_RevertWhen_SetLendingPoolZero() public {
        vm.prank(admin);
        vm.expectRevert(InvoiceNFT.ZeroAddress.selector);
        nft.setLendingPool(address(0));
    }

    // ----------------------------------------------------------------- lifecycle

    function test_RevertWhen_CancelAfterFinanced() public {
        (uint256 id,) = _financed();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceRegistry.InvalidStatus.selector, id, InvoiceRegistry.Status.Financed)
        );
        registry.cancel(id);
    }

    function test_RevertWhen_NonSellerCancels() public {
        uint256 id = _register(FACE);
        vm.prank(agent);
        vm.expectRevert(InvoiceRegistry.NotSeller.selector);
        registry.cancel(id);
    }

    function test_RevertWhen_NonBuyerPays() public {
        uint256 id = _registerAndConfirm(FACE);
        vm.prank(stranger);
        vm.expectRevert(RepaymentEscrow.NotBuyer.selector);
        escrow.pay(id);
    }

    function test_RevertWhen_PayUnconfirmedOrRepaid() public {
        uint256 id = _register(FACE);
        vm.prank(buyerA);
        vm.expectRevert(
            abi.encodeWithSelector(RepaymentEscrow.NotPayable.selector, id, InvoiceRegistry.Status.Registered)
        );
        escrow.pay(id);

        vm.prank(buyerA);
        registry.confirmByBuyer(id);
        vm.prank(buyerA);
        escrow.pay(id);
        vm.prank(buyerA);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.NotPayable.selector, id, InvoiceRegistry.Status.Repaid));
        escrow.pay(id); // no double payment
    }

    function test_MarkDefaulted_AfterGracePeriod() public {
        (uint256 id,) = _financed();

        vm.warp(uint256(dueDate) + 7 days);
        vm.expectRevert(InvoiceRegistry.GracePeriodNotOver.selector);
        registry.markDefaulted(id);

        vm.warp(uint256(dueDate) + 7 days + 1);
        vm.prank(stranger); // anyone can flag
        registry.markDefaulted(id);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Defaulted));

        // Late payment still settles through the waterfall (recovery path)
        vm.prank(buyerA);
        escrow.pay(id);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Repaid));
        assertEq(pool.totalOutstanding(), 0);
        assertEq(pool.availableLiquidity(), POOL_DEPOSIT + FEE);
    }

    function test_RevertWhen_MarkDefaultedNotFinanced() public {
        uint256 id = _registerAndConfirm(FACE);
        vm.warp(uint256(dueDate) + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceRegistry.InvalidStatus.selector, id, InvoiceRegistry.Status.Confirmed)
        );
        registry.markDefaulted(id);
    }
}
