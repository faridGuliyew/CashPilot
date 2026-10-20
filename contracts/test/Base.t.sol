// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {InvoiceNFT} from "../src/InvoiceNFT.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {FinancingController} from "../src/FinancingController.sol";
import {RepaymentEscrow} from "../src/RepaymentEscrow.sol";

/// @dev Shared deployment + helpers. Wiring mirrors script/Deploy.s.sol.
abstract contract BaseTest is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant PER_INVOICE_CAP = 10_000 * USDC;
    uint256 internal constant DAILY_CAP = 20_000 * USDC;
    uint256 internal constant POOL_DEPOSIT = 80_000 * USDC;

    // Default invoice: Caspian Hotels, 12,000 mUSDC, due in 45 days
    uint256 internal constant FACE = 12_000 * USDC;
    uint256 internal constant ADVANCE = 9_600 * USDC; // 80%
    uint256 internal constant FEE = 120 * USDC; // 1%

    address internal admin = makeAddr("admin");
    address internal agent = makeAddr("agent");
    address internal owner = makeAddr("owner"); // SME owner = seller
    address internal lp = makeAddr("lp");
    address internal stranger = makeAddr("stranger");
    address internal buyerA;
    uint256 internal buyerAKey;
    address internal buyerB = makeAddr("buyerB");

    MockUSDC internal usdc;
    InvoiceNFT internal nft;
    InvoiceRegistry internal registry;
    LendingPool internal pool;
    FinancingController internal controller;
    RepaymentEscrow internal escrow;

    uint64 internal dueDate;
    uint256 internal invoiceCounter;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        (buyerA, buyerAKey) = makeAddrAndKey("buyerA");
        dueDate = uint64(block.timestamp + 45 days);

        vm.startPrank(admin);
        usdc = new MockUSDC(admin);
        nft = new InvoiceNFT(admin);
        registry = new InvoiceRegistry(admin, nft);
        pool = new LendingPool(admin, usdc);
        controller = new FinancingController(admin, registry, nft, pool, PER_INVOICE_CAP, DAILY_CAP);
        escrow = new RepaymentEscrow(usdc, registry, nft, pool, controller);

        nft.setLendingPool(address(pool));
        nft.grantRole(nft.MINTER_ROLE(), address(registry));
        nft.grantRole(nft.BURNER_ROLE(), address(registry));
        nft.grantRole(nft.BURNER_ROLE(), address(escrow));
        nft.grantRole(nft.CONTROLLER_ROLE(), address(controller));
        registry.grantRole(registry.CONTROLLER_ROLE(), address(controller));
        registry.grantRole(registry.ESCROW_ROLE(), address(escrow));
        registry.grantRole(registry.PROPOSER_ROLE(), agent);
        pool.grantRole(pool.CONTROLLER_ROLE(), address(controller));
        pool.grantRole(pool.ESCROW_ROLE(), address(escrow));
        controller.grantRole(controller.PROPOSER_ROLE(), agent);

        usdc.mint(lp, 100_000 * USDC);
        usdc.mint(buyerA, 50_000 * USDC);
        usdc.mint(buyerB, 50_000 * USDC);
        vm.stopPrank();

        vm.prank(owner);
        registry.setAuthorizedAgent(agent, true);

        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(POOL_DEPOSIT);
        vm.stopPrank();

        vm.prank(buyerA);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(buyerB);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ----------------------------------------------------------------- helpers

    function _invoiceHash(string memory number, uint256 face, uint64 due) internal pure returns (bytes32) {
        return keccak256(abi.encode("AZ-1402345671", "AZ-9900112233", number, face, due));
    }

    function _register(uint256 face) internal returns (uint256 id) {
        invoiceCounter++;
        bytes32 h = _invoiceHash(string.concat("INV-", vm.toString(invoiceCounter)), face, dueDate);
        vm.prank(agent);
        id = registry.registerInvoice(h, owner, buyerA, face, dueDate);
    }

    function _registerAndConfirm(uint256 face) internal returns (uint256 id) {
        id = _register(face);
        vm.prank(buyerA);
        registry.confirmByBuyer(id);
    }

    function _propose(uint256 invoiceId, uint256 advance, uint256 fee) internal returns (uint256 pid) {
        vm.prank(agent);
        pid = controller.propose(invoiceId, advance, fee);
    }

    function _financed() internal returns (uint256 id, uint256 pid) {
        id = _registerAndConfirm(FACE);
        pid = _propose(id, ADVANCE, FEE);
        vm.prank(owner);
        controller.approve(pid);
    }

    function _signConfirmation(uint256 key, uint256 invoiceId) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registry.confirmationDigest(invoiceId));
        return abi.encodePacked(r, s, v);
    }
}
