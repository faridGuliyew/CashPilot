// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {AgreementLedger} from "../src/AgreementLedger.sol";

/// @dev Shared deployment + helpers. Wiring mirrors script/Deploy.s.sol.
abstract contract BaseTest is Test {
    // Amounts in kuruş (TL minor units, 2 decimals)
    uint256 internal constant TL = 100;
    uint256 internal constant FACE = 100_000 * TL; // Beta Markets invoice
    uint256 internal constant X = 60_000 * TL; // face amount settled early
    uint32 internal constant DISCOUNT_BPS = 200; // 2%
    uint256 internal constant PAY = 58_800 * TL;

    address internal admin = makeAddr("admin");
    address internal coordinator = makeAddr("coordinator");
    address internal stranger = makeAddr("stranger");
    address internal supplier; // Alpha Foods signer
    uint256 internal supplierKey;
    address internal buyer; // Beta Markets signer
    uint256 internal buyerKey;

    InvoiceRegistry internal registry;
    AgreementLedger internal ledger;

    uint64 internal dueDate;
    uint256 internal invoiceCounter;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        (supplier, supplierKey) = makeAddrAndKey("supplier");
        (buyer, buyerKey) = makeAddrAndKey("buyer");
        dueDate = uint64(block.timestamp + 60 days);

        vm.startPrank(admin);
        registry = new InvoiceRegistry(admin);
        ledger = new AgreementLedger(admin, registry);
        registry.grantRole(registry.SETTLER_ROLE(), address(ledger));
        registry.grantRole(registry.REGISTRAR_ROLE(), coordinator);
        ledger.grantRole(ledger.COORDINATOR_ROLE(), coordinator);
        vm.stopPrank();

        vm.prank(supplier);
        registry.setAuthorizedRegistrar(coordinator, true);
    }

    // ----------------------------------------------------------------- helpers

    function _invoiceHash(string memory number, uint256 face, uint64 due) internal pure returns (bytes32) {
        return keccak256(abi.encode("TR-1111111111", "TR-2222222222", number, face, due));
    }

    function _register(uint256 face) internal returns (uint256 id) {
        invoiceCounter++;
        bytes32 h = _invoiceHash(string.concat("INV-", vm.toString(invoiceCounter)), face, dueDate);
        vm.prank(coordinator);
        id = registry.registerInvoice(h, supplier, buyer, face, dueDate);
    }

    function _registerAndConfirm(uint256 face) internal returns (uint256 id) {
        id = _register(face);
        vm.prank(buyer);
        registry.confirmByBuyer(id);
    }

    function _agreement(uint256 invoiceId, uint32 version) internal view returns (AgreementLedger.Agreement memory a) {
        InvoiceRegistry.Invoice memory inv = registry.getInvoice(invoiceId);
        a = AgreementLedger.Agreement({
            agreementId: keccak256(abi.encodePacked("AGR-", vm.toString(invoiceId))),
            version: version,
            invoiceId: invoiceId,
            invoiceHash: inv.invoiceHash,
            seller: inv.seller,
            buyer: inv.buyer,
            faceAmount: X,
            discountBps: DISCOUNT_BPS,
            payAmount: PAY,
            currency: bytes32("TRY"),
            payeeAccountHash: keccak256("TR00 0000 ALPHA FOODS"),
            expiresAt: uint64(block.timestamp + 1 days),
            idempotencyKeyHash: keccak256(abi.encodePacked("idem-", vm.toString(invoiceId), "-", vm.toString(version)))
        });
    }

    function _commit(AgreementLedger.Agreement memory a) internal returns (bytes32 h) {
        vm.prank(coordinator);
        h = ledger.commitAgreement(a);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _approveBoth(bytes32 h) internal {
        ledger.approve(h, _sign(supplierKey, h));
        ledger.approve(h, _sign(buyerKey, h));
    }

    /// @dev Confirmed invoice + committed v1 agreement.
    function _committed() internal returns (uint256 id, bytes32 h) {
        id = _registerAndConfirm(FACE);
        h = _commit(_agreement(id, 1));
    }
}
