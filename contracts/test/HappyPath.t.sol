// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {FinancingController} from "../src/FinancingController.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract HappyPathTest is BaseTest {
    function test_FullFlow_RegisterConfirmProposeApprovePay() public {
        // 1. Agent registers on behalf of the owner
        uint256 id = _register(FACE);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Registered));
        assertEq(nft.balanceOf(owner), 0);

        // 2. Buyer confirms -> NFT minted to seller
        vm.prank(buyerA);
        registry.confirmByBuyer(id);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Confirmed));
        assertEq(nft.ownerOf(id), owner);

        // 3. Agent proposes; nothing moves yet
        uint256 pid = _propose(id, ADVANCE, FEE);
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(pool.availableLiquidity(), POOL_DEPOSIT);
        FinancingController.Proposal memory p = controller.getProposal(pid);
        assertEq(p.advanceAmount, ADVANCE);
        assertEq(p.expiresAt, block.timestamp + 1 hours);

        // 4. Owner approves -> advance paid, NFT locked in pool
        vm.prank(owner);
        controller.approve(pid);
        assertEq(usdc.balanceOf(owner), ADVANCE);
        assertEq(pool.availableLiquidity(), POOL_DEPOSIT - ADVANCE);
        assertEq(pool.totalOutstanding(), ADVANCE);
        assertEq(pool.totalAssets(), POOL_DEPOSIT);
        assertEq(nft.ownerOf(id), address(pool));
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Financed));

        // 5. Buyer pays face value -> pool repaid first, remainder to seller, NFT burned
        uint256 buyerBefore = usdc.balanceOf(buyerA);
        vm.prank(buyerA);
        escrow.pay(id);
        assertEq(usdc.balanceOf(buyerA), buyerBefore - FACE);
        assertEq(pool.totalOutstanding(), 0);
        assertEq(pool.availableLiquidity(), POOL_DEPOSIT + FEE);
        assertEq(pool.balanceOfAssets(lp), POOL_DEPOSIT + FEE);
        assertEq(usdc.balanceOf(owner), ADVANCE + (FACE - ADVANCE - FEE)); // = FACE - FEE
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Repaid));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);
    }

    function test_PayWithoutFinancing_AllToSeller() public {
        uint256 id = _registerAndConfirm(FACE);
        vm.prank(buyerA);
        escrow.pay(id);
        assertEq(usdc.balanceOf(owner), FACE);
        assertEq(pool.availableLiquidity(), POOL_DEPOSIT);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Repaid));
        assertEq(nft.balanceOf(owner), 0);
    }

    function test_ConfirmWithEIP712Signature() public {
        uint256 id = _register(FACE);

        // Rebuild the digest independently so off-chain signers (Python) can match it.
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CashPilot InvoiceRegistry"),
                keccak256("1"),
                block.chainid,
                address(registry)
            )
        );
        InvoiceRegistry.Invoice memory inv = registry.getInvoice(id);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("InvoiceConfirmation(uint256 invoiceId,bytes32 invoiceHash,uint256 faceValue,uint64 dueDate)"),
                id,
                inv.invoiceHash,
                inv.faceValue,
                inv.dueDate
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        assertEq(digest, registry.confirmationDigest(id));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerAKey, digest);
        vm.prank(stranger); // anyone can relay the buyer's signature
        registry.confirmByBuyerWithSig(id, abi.encodePacked(r, s, v));

        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Confirmed));
        assertEq(nft.ownerOf(id), owner);

        // Replaying the same signature fails: invoice is no longer Registered
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceRegistry.InvalidStatus.selector, id, InvoiceRegistry.Status.Confirmed)
        );
        registry.confirmByBuyerWithSig(id, abi.encodePacked(r, s, v));
    }

    function test_SellerRegistersDirectly() public {
        bytes32 h = _invoiceHash("SELF-1", FACE, dueDate);
        vm.prank(owner);
        uint256 id = registry.registerInvoice(h, owner, buyerA, FACE, dueDate);
        assertEq(registry.getInvoice(id).seller, owner);
        assertTrue(registry.hashUsed(h));
    }

    function test_OwnerRejectsProposal() public {
        uint256 id = _registerAndConfirm(FACE);
        uint256 pid = _propose(id, ADVANCE, FEE);
        vm.prank(owner);
        controller.reject(pid);
        assertEq(uint8(controller.getProposal(pid).status), uint8(FinancingController.ProposalStatus.Rejected));
        // Rejected proposal can no longer be approved
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FinancingController.ProposalNotPending.selector, pid));
        controller.approve(pid);
        // Agent can propose again with different terms
        uint256 pid2 = _propose(id, 6_000 * USDC, 60 * USDC);
        vm.prank(owner);
        controller.approve(pid2);
        assertEq(usdc.balanceOf(owner), 6_000 * USDC);
    }

    function test_CancelConfirmedInvoice_BurnsNFT() public {
        uint256 id = _registerAndConfirm(FACE);
        vm.prank(owner);
        registry.cancel(id);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Cancelled));
        assertEq(nft.balanceOf(owner), 0);
        // Hash stays burned: cannot be re-registered
        assertTrue(registry.hashUsed(registry.getInvoice(id).invoiceHash));
    }

    function test_CancelRegisteredInvoice() public {
        uint256 id = _register(FACE);
        vm.prank(owner);
        registry.cancel(id);
        assertEq(uint8(registry.statusOf(id)), uint8(InvoiceRegistry.Status.Cancelled));
    }

    function test_LPEarnsFeeAndWithdraws() public {
        (uint256 id,) = _financed();
        vm.prank(buyerA);
        escrow.pay(id);

        // Second LP enters after the fee accrued and gets fewer shares per mUSDC
        address lp2 = makeAddr("lp2");
        vm.prank(admin);
        usdc.mint(lp2, 10_000 * USDC);
        vm.startPrank(lp2);
        usdc.approve(address(pool), type(uint256).max);
        uint256 shares2 = pool.deposit(10_000 * USDC);
        vm.stopPrank();
        assertLt(shares2, 10_000 * USDC);
        assertApproxEqAbs(pool.balanceOfAssets(lp2), 10_000 * USDC, 1);

        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        pool.withdraw(POOL_DEPOSIT + FEE);
        assertEq(usdc.balanceOf(lp), lpBefore + POOL_DEPOSIT + FEE);
        assertEq(pool.sharesOf(lp), 0);
    }

    function test_UtilizationView() public {
        assertEq(pool.utilizationBps(), 0);
        _financed();
        assertEq(pool.utilizationBps(), (ADVANCE * 10_000) / POOL_DEPOSIT); // 1200 bps
    }

    function test_AdminCanUnpause() public {
        vm.startPrank(admin);
        controller.pause();
        controller.unpause();
        vm.stopPrank();
        _financed();
        assertEq(usdc.balanceOf(owner), ADVANCE);
    }

    function test_AdminSetsLimits() public {
        vm.prank(admin);
        controller.setLimits(5_000 * USDC, 7_000 * USDC);
        assertEq(controller.perInvoiceCap(), 5_000 * USDC);
        assertEq(controller.dailyCapPerSeller(), 7_000 * USDC);
    }
}
