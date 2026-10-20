// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {InvoiceRegistry} from "./InvoiceRegistry.sol";
import {InvoiceNFT} from "./InvoiceNFT.sol";
import {LendingPool} from "./LendingPool.sol";

/// @title FinancingController
/// @notice Two-step financing: the agent (PROPOSER_ROLE, tier T2) proposes an advance; only the
///         invoice's seller (owner key, tier T3) can approve it, which moves the money.
///         Limits and pause are admin-only (tier T4) — the agent holds no admin role.
contract FinancingController is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ADVANCE_BPS = 8_000; // 80% of face value, regardless of risk grade
    uint256 public constant MAX_FEE_BPS = 500; // 5% of face value
    uint256 public constant PROPOSAL_TTL = 1 hours;

    enum ProposalStatus {
        None,
        Pending,
        Approved,
        Rejected
    }

    struct Proposal {
        uint256 invoiceId;
        uint256 advanceAmount;
        uint256 feeAmount;
        uint64 expiresAt;
        address proposer;
        ProposalStatus status;
    }

    struct Financing {
        uint256 advanceAmount;
        uint256 feeAmount;
        uint256 proposalId;
    }

    InvoiceRegistry public immutable registry;
    InvoiceNFT public immutable nft;
    LendingPool public immutable pool;

    uint256 public perInvoiceCap;
    uint256 public dailyCapPerSeller;

    uint256 public nextProposalId = 1;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => Financing) private _financings; // by invoiceId
    mapping(address => mapping(uint256 => uint256)) public dailyVolume; // seller => day => advanced

    error InvoiceNotConfirmed(uint256 invoiceId);
    error ZeroAdvance();
    error AdvanceAboveMaxRate(uint256 advance, uint256 max);
    error AdvanceAbovePerInvoiceCap(uint256 advance, uint256 cap);
    error FeeAboveMax(uint256 fee, uint256 max);
    error AgentCannotApprove();
    error NotInvoiceSeller();
    error ProposalNotPending(uint256 proposalId);
    error ProposalExpired(uint256 proposalId);
    error DailyCapExceeded(uint256 volumeAfter, uint256 cap);

    event LimitsSet(uint256 perInvoiceCap, uint256 dailyCapPerSeller);
    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed invoiceId,
        address indexed proposer,
        uint256 advanceAmount,
        uint256 feeAmount,
        uint64 expiresAt
    );
    event ProposalApproved(uint256 indexed proposalId, uint256 indexed invoiceId, address indexed seller);
    event ProposalRejected(uint256 indexed proposalId, uint256 indexed invoiceId, address indexed seller);

    constructor(
        address admin,
        InvoiceRegistry registry_,
        InvoiceNFT nft_,
        LendingPool pool_,
        uint256 perInvoiceCap_,
        uint256 dailyCapPerSeller_
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        registry = registry_;
        nft = nft_;
        pool = pool_;
        _setLimits(perInvoiceCap_, dailyCapPerSeller_);
    }

    // ----------------------------------------------------------------- T2: agent proposes

    function propose(uint256 invoiceId, uint256 advanceAmount, uint256 feeAmount)
        external
        onlyRole(PROPOSER_ROLE)
        whenNotPaused
        returns (uint256 proposalId)
    {
        InvoiceRegistry.Invoice memory inv = registry.getInvoice(invoiceId);
        if (inv.status != InvoiceRegistry.Status.Confirmed) revert InvoiceNotConfirmed(invoiceId);
        if (advanceAmount == 0) revert ZeroAdvance();
        uint256 maxAdvance = (inv.faceValue * MAX_ADVANCE_BPS) / BPS;
        if (advanceAmount > maxAdvance) revert AdvanceAboveMaxRate(advanceAmount, maxAdvance);
        if (advanceAmount > perInvoiceCap) revert AdvanceAbovePerInvoiceCap(advanceAmount, perInvoiceCap);
        uint256 maxFee = (inv.faceValue * MAX_FEE_BPS) / BPS;
        if (feeAmount > maxFee) revert FeeAboveMax(feeAmount, maxFee);

        proposalId = nextProposalId++;
        uint64 expiresAt = uint64(block.timestamp + PROPOSAL_TTL);
        _proposals[proposalId] =
            Proposal(invoiceId, advanceAmount, feeAmount, expiresAt, msg.sender, ProposalStatus.Pending);
        emit ProposalCreated(proposalId, invoiceId, msg.sender, advanceAmount, feeAmount, expiresAt);
    }

    // ----------------------------------------------------------------- T3: owner approves

    function approve(uint256 proposalId) external nonReentrant whenNotPaused {
        // A proposer can never approve, even for an invoice where it is the seller.
        if (hasRole(PROPOSER_ROLE, msg.sender)) revert AgentCannotApprove();

        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.Pending) revert ProposalNotPending(proposalId);
        if (block.timestamp > p.expiresAt) revert ProposalExpired(proposalId);

        InvoiceRegistry.Invoice memory inv = registry.getInvoice(p.invoiceId);
        if (msg.sender != inv.seller) revert NotInvoiceSeller();
        if (inv.status != InvoiceRegistry.Status.Confirmed) revert InvoiceNotConfirmed(p.invoiceId);

        uint256 day = block.timestamp / 1 days;
        uint256 volumeAfter = dailyVolume[inv.seller][day] + p.advanceAmount;
        if (volumeAfter > dailyCapPerSeller) revert DailyCapExceeded(volumeAfter, dailyCapPerSeller);

        // effects
        p.status = ProposalStatus.Approved;
        dailyVolume[inv.seller][day] = volumeAfter;
        _financings[p.invoiceId] = Financing(p.advanceAmount, p.feeAmount, proposalId);

        emit ProposalApproved(proposalId, p.invoiceId, msg.sender);

        // interactions (trusted protocol contracts)
        registry.setFinanced(p.invoiceId);
        nft.lockToPool(p.invoiceId);
        pool.disburse(inv.seller, p.advanceAmount); // enforces liquidity + utilization cap
    }

    function reject(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.Pending) revert ProposalNotPending(proposalId);
        if (msg.sender != registry.getInvoice(p.invoiceId).seller) revert NotInvoiceSeller();
        p.status = ProposalStatus.Rejected;
        emit ProposalRejected(proposalId, p.invoiceId, msg.sender);
    }

    // ----------------------------------------------------------------- T4: admin only

    function setLimits(uint256 perInvoiceCap_, uint256 dailyCapPerSeller_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLimits(perInvoiceCap_, dailyCapPerSeller_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _setLimits(uint256 perInvoiceCap_, uint256 dailyCapPerSeller_) private {
        perInvoiceCap = perInvoiceCap_;
        dailyCapPerSeller = dailyCapPerSeller_;
        emit LimitsSet(perInvoiceCap_, dailyCapPerSeller_);
    }

    // ----------------------------------------------------------------- views

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function financingOf(uint256 invoiceId) external view returns (Financing memory) {
        return _financings[invoiceId];
    }
}
