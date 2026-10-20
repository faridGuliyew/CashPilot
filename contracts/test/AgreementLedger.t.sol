// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {AgreementLedger} from "../src/AgreementLedger.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Test names are referenced in docs/SECURITY_SELF_ASSESSMENT.md.
contract AgreementLedgerTest is BaseTest {
    bytes32 internal constant PAYMENT_ID = keccak256("pay_0001");
    bytes32 internal constant RECEIPT = keccak256("receipt_0001");

    // ----------------------------------------------------------------- happy path

    function test_HappyPath_CommitApproveSubmitSettle() public {
        uint256 id = _registerAndConfirm(FACE);
        AgreementLedger.Agreement memory a = _agreement(id, 1);
        bytes32 h = _commit(a);
        assertEq(h, ledger.hashAgreement(a));
        assertEq(ledger.activeAgreementOf(id), h);

        ledger.approve(h, _sign(supplierKey, h));
        assertFalse(ledger.isFullyApproved(h));
        bytes memory buyerSig = _sign(buyerKey, h);
        vm.prank(stranger); // anyone can relay a signature
        ledger.approve(h, buyerSig);
        assertTrue(ledger.isFullyApproved(h));

        vm.prank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        assertEq(uint8(ledger.getRecord(h).status), uint8(AgreementLedger.Status.Submitted));

        vm.prank(coordinator);
        ledger.recordSettlement(h, RECEIPT);
        AgreementLedger.Record memory r = ledger.getRecord(h);
        assertEq(uint8(r.status), uint8(AgreementLedger.Status.Settled));
        assertEq(r.bankPaymentIdHash, PAYMENT_ID);
        assertEq(r.settlementReceiptHash, RECEIPT);
        assertEq(ledger.activeAgreementOf(id), bytes32(0));
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Settled));
    }

    function test_AgreementHashMatchesOffChainEIP712() public {
        uint256 id = _registerAndConfirm(FACE);
        AgreementLedger.Agreement memory a = _agreement(id, 1);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AuditFlow AgreementLedger"),
                keccak256("1"),
                block.chainid,
                address(ledger)
            )
        );
        // All fields are static, so encodeData is the plain concatenation of 32-byte words.
        bytes memory head = abi.encode(
            keccak256(
                "Agreement(bytes32 agreementId,uint32 version,uint256 invoiceId,bytes32 invoiceHash,address seller,address buyer,uint256 faceAmount,uint32 discountBps,uint256 payAmount,bytes32 currency,bytes32 payeeAccountHash,uint64 expiresAt,bytes32 idempotencyKeyHash)"
            ),
            a.agreementId,
            a.version,
            a.invoiceId,
            a.invoiceHash,
            a.seller,
            a.buyer
        );
        bytes memory tail = abi.encode(
            a.faceAmount, a.discountBps, a.payAmount, a.currency, a.payeeAccountHash, a.expiresAt, a.idempotencyKeyHash
        );
        bytes32 structHash = keccak256(bytes.concat(head, tail));
        assertEq(domain, ledger.domainSeparator());
        assertEq(ledger.hashAgreement(a), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function test_FailedPaymentFreesInvoiceForNewVersion() public {
        (uint256 id, bytes32 h) = _committed();
        _approveBoth(h);
        vm.startPrank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        ledger.recordFailure(h, keccak256("INSUFFICIENT_FUNDS"));
        vm.stopPrank();
        assertEq(uint8(ledger.getRecord(h).status), uint8(AgreementLedger.Status.Failed));
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Confirmed));
        bytes32 h2 = _commit(_agreement(id, 2));
        assertEq(ledger.activeAgreementOf(id), h2);
    }

    // ----------------------------------------------------------------- invoice checks

    function test_RevertWhen_DuplicateInvoice() public {
        // Same invoice hash cannot be registered twice, so it cannot get two parallel agreements.
        bytes32 h = _invoiceHash("BETA-0001", FACE, dueDate);
        vm.prank(coordinator);
        registry.registerInvoice(h, supplier, buyer, FACE, dueDate);
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(InvoiceRegistry.DuplicateInvoice.selector, h));
        registry.registerInvoice(h, supplier, buyer, FACE, dueDate);
    }

    function test_RevertWhen_CommitOnUnconfirmedInvoice() public {
        uint256 id = _register(FACE); // forged / not confirmed by the buyer
        AgreementLedger.Agreement memory a = _agreement(id, 1);
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.InvoiceNotConfirmed.selector, id));
        ledger.commitAgreement(a);
    }

    function test_RevertWhen_CommitOnSettledInvoice() public {
        (uint256 id, bytes32 h) = _committed();
        _approveBoth(h);
        AgreementLedger.Agreement memory a = _agreement(id, 2);
        vm.startPrank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        ledger.recordSettlement(h, RECEIPT);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.InvoiceNotConfirmed.selector, id));
        ledger.commitAgreement(a);
        vm.stopPrank();
    }

    function test_RevertWhen_CommitMismatchesInvoice() public {
        uint256 id = _registerAndConfirm(FACE);
        AgreementLedger.Agreement memory a = _agreement(id, 1);
        a.seller = stranger; // pay-to-attacker attempt
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.AgreementMismatch.selector);
        ledger.commitAgreement(a);

        a = _agreement(id, 1);
        a.invoiceHash = keccak256("other");
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.AgreementMismatch.selector);
        ledger.commitAgreement(a);
    }

    function test_RevertWhen_CommitInvalidTerms() public {
        uint256 id = _registerAndConfirm(FACE);
        AgreementLedger.Agreement memory a = _agreement(id, 1);

        a.payAmount = PAY + 1; // does not match faceAmount * (1 - discount)
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.InvalidTerms.selector);
        ledger.commitAgreement(a);

        a = _agreement(id, 1);
        a.faceAmount = FACE + 1; // more than the invoice
        a.payAmount = (a.faceAmount * (10_000 - DISCOUNT_BPS)) / 10_000;
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.InvalidTerms.selector);
        ledger.commitAgreement(a);

        a = _agreement(id, 1);
        a.discountBps = 10_000;
        a.payAmount = 0;
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.InvalidTerms.selector);
        ledger.commitAgreement(a);

        a = _agreement(id, 1);
        a.expiresAt = uint64(block.timestamp);
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.InvalidTerms.selector);
        ledger.commitAgreement(a);
    }

    function test_RevertWhen_SecondActiveAgreement() public {
        (uint256 id, bytes32 h) = _committed();
        AgreementLedger.Agreement memory a2 = _agreement(id, 2);
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.ActiveAgreementExists.selector, h));
        ledger.commitAgreement(a2);
    }

    function test_RevertWhen_VersionNotIncreasing() public {
        (uint256 id, bytes32 h) = _committed();
        vm.prank(coordinator);
        ledger.supersede(h);
        AgreementLedger.Agreement memory again = _agreement(id, 1);
        again.discountBps = 150;
        again.payAmount = (X * (10_000 - 150)) / 10_000;
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.VersionNotIncreasing.selector, 1, 1));
        ledger.commitAgreement(again);
    }

    // ----------------------------------------------------------------- approvals (T3)

    function test_RevertWhen_ApprovalWithWrongSigner() public {
        (, bytes32 h) = _committed();
        (address attacker, uint256 attackerKey) = makeAddrAndKey("attacker");
        bytes memory sig = _sign(attackerKey, h);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.InvalidSigner.selector, attacker));
        ledger.approve(h, sig);

        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.InvalidSigner.selector, address(0)));
        ledger.approve(h, hex"deadbeef");
        assertFalse(ledger.getRecord(h).sellerApproved);
        assertFalse(ledger.getRecord(h).buyerApproved);
    }

    function test_RevertWhen_ApprovalReplayed() public {
        (, bytes32 h) = _committed();
        bytes memory sig = _sign(supplierKey, h);
        ledger.approve(h, sig);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.AlreadyApproved.selector, h, supplier));
        ledger.approve(h, sig);
    }

    function test_RevertWhen_ApprovalOnSupersededVersion() public {
        (uint256 id, bytes32 h1) = _committed();
        bytes memory oldSellerSig = _sign(supplierKey, h1);
        bytes memory oldBuyerSig = _sign(buyerKey, h1);
        ledger.approve(h1, oldSellerSig);

        // Amount changes -> new version, old one superseded
        vm.prank(coordinator);
        ledger.supersede(h1);
        AgreementLedger.Agreement memory a2 = _agreement(id, 2);
        a2.faceAmount = 70_000 * TL;
        a2.payAmount = (a2.faceAmount * (10_000 - DISCOUNT_BPS)) / 10_000;
        bytes32 h2 = _commit(a2);
        assertTrue(h2 != h1);

        vm.expectRevert(
            abi.encodeWithSelector(AgreementLedger.InvalidStatus.selector, h1, AgreementLedger.Status.Superseded)
        );
        ledger.approve(h1, oldBuyerSig);

        // Old signatures do not count for the new hash
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.InvalidSigner.selector, _recover(h2, oldSellerSig)));
        ledger.approve(h2, oldSellerSig);
        assertFalse(ledger.getRecord(h2).sellerApproved);

        // Superseded version cannot be submitted either
        vm.prank(coordinator);
        vm.expectRevert(
            abi.encodeWithSelector(AgreementLedger.InvalidStatus.selector, h1, AgreementLedger.Status.Superseded)
        );
        ledger.recordSubmission(h1, PAYMENT_ID);
    }

    function test_RevertWhen_ApprovalAfterExpiry() public {
        (, bytes32 h) = _committed();
        bytes memory sig = _sign(supplierKey, h);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.AgreementExpired.selector, h));
        ledger.approve(h, sig);
    }

    // ----------------------------------------------------------------- submission / settlement (T4)

    function test_RevertWhen_SubmissionWithOneApproval() public {
        (, bytes32 h) = _committed();
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.MissingApprovals.selector, false, false));
        ledger.recordSubmission(h, PAYMENT_ID);

        ledger.approve(h, _sign(supplierKey, h));
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.MissingApprovals.selector, true, false));
        ledger.recordSubmission(h, PAYMENT_ID);
    }

    function test_RevertWhen_SubmissionAfterExpiry() public {
        (, bytes32 h) = _committed();
        _approveBoth(h);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.AgreementExpired.selector, h));
        ledger.recordSubmission(h, PAYMENT_ID);
    }

    function test_RevertWhen_SubmissionAfterInvoiceCancelled() public {
        (uint256 id, bytes32 h) = _committed();
        _approveBoth(h);
        vm.prank(supplier);
        registry.cancel(id);
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(AgreementLedger.InvoiceNotConfirmed.selector, id));
        ledger.recordSubmission(h, PAYMENT_ID);
    }

    function test_RevertWhen_SubmissionWithoutPaymentId() public {
        (, bytes32 h) = _committed();
        _approveBoth(h);
        vm.prank(coordinator);
        vm.expectRevert(AgreementLedger.ZeroReference.selector);
        ledger.recordSubmission(h, bytes32(0));
    }

    function test_RevertWhen_SettlementBeforeSubmission() public {
        (, bytes32 h) = _committed();
        _approveBoth(h);
        vm.startPrank(coordinator);
        vm.expectRevert(
            abi.encodeWithSelector(AgreementLedger.InvalidStatus.selector, h, AgreementLedger.Status.Committed)
        );
        ledger.recordSettlement(h, RECEIPT);
        vm.expectRevert(
            abi.encodeWithSelector(AgreementLedger.InvalidStatus.selector, h, AgreementLedger.Status.Committed)
        );
        ledger.recordFailure(h, keccak256("x"));
        vm.stopPrank();
    }

    function test_RevertWhen_SettlementTwiceOrWithoutReceipt() public {
        (, bytes32 h) = _committed();
        _approveBoth(h);
        vm.startPrank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        vm.expectRevert(AgreementLedger.ZeroReference.selector);
        ledger.recordSettlement(h, bytes32(0));
        ledger.recordSettlement(h, RECEIPT);
        vm.expectRevert(
            abi.encodeWithSelector(AgreementLedger.InvalidStatus.selector, h, AgreementLedger.Status.Settled)
        );
        ledger.recordSettlement(h, RECEIPT);
        vm.stopPrank();
    }

    function test_RevertWhen_SupersedeAfterSubmission() public {
        (, bytes32 h) = _committed();
        _approveBoth(h);
        vm.startPrank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        vm.expectRevert(
            abi.encodeWithSelector(AgreementLedger.InvalidStatus.selector, h, AgreementLedger.Status.Submitted)
        );
        ledger.supersede(h);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- access control

    function test_RevertWhen_NonCoordinatorCalls() public {
        (uint256 id, bytes32 h) = _committed();
        _approveBoth(h);
        bytes32 role = ledger.COORDINATOR_ROLE();
        AgreementLedger.Agreement memory a = _agreement(id, 2);

        address[3] memory callers = [supplier, buyer, admin];
        for (uint256 i = 0; i < callers.length; i++) {
            address c = callers[i];
            bytes memory err = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, c, role);
            vm.startPrank(c);
            vm.expectRevert(err);
            ledger.commitAgreement(a);
            vm.expectRevert(err);
            ledger.supersede(h);
            vm.expectRevert(err);
            ledger.recordSubmission(h, PAYMENT_ID);
            vm.expectRevert(err);
            ledger.recordSettlement(h, RECEIPT);
            vm.expectRevert(err);
            ledger.recordFailure(h, RECEIPT);
            vm.stopPrank();
        }
    }

    function test_RevertWhen_NonAdminPausesOrGrantsRoles() public {
        bytes32 adminRole = ledger.DEFAULT_ADMIN_ROLE();
        bytes memory err =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, coordinator, adminRole);
        vm.startPrank(coordinator);
        vm.expectRevert(err);
        ledger.pause();
        vm.expectRevert(err);
        ledger.unpause();
        vm.expectRevert(err);
        ledger.grantRole(adminRole, coordinator);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- pause

    function test_RevertWhen_Paused() public {
        (uint256 id, bytes32 h) = _committed();
        bytes memory sellerSig = _sign(supplierKey, h);
        uint256 id2 = _registerAndConfirm(FACE);
        AgreementLedger.Agreement memory a2 = _agreement(id2, 1);

        vm.prank(admin);
        ledger.pause();

        vm.prank(coordinator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ledger.commitAgreement(a2);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ledger.approve(h, sellerSig);
        vm.prank(coordinator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ledger.recordSubmission(h, PAYMENT_ID);

        vm.prank(admin);
        ledger.unpause();
        _approveBoth(h);
        vm.prank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        assertEq(ledger.activeAgreementOf(id), h);
    }

    function test_SettlementStillRecordedWhilePaused() public {
        (, bytes32 h) = _committed();
        _approveBoth(h);
        vm.prank(coordinator);
        ledger.recordSubmission(h, PAYMENT_ID);
        vm.prank(admin);
        ledger.pause();
        // Money already moved at the bank: the ledger must still be able to record it.
        vm.prank(coordinator);
        ledger.recordSettlement(h, RECEIPT);
        assertEq(uint8(ledger.getRecord(h).status), uint8(AgreementLedger.Status.Settled));
    }

    // ----------------------------------------------------------------- helpers

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(digest, v, r, s);
    }
}
