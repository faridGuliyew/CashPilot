// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {InvoiceNFT} from "./InvoiceNFT.sol";

/// @title InvoiceRegistry
/// @notice Registers invoices by hash (double-financing protection), records the buyer's
///         confirmation (on-chain call or EIP-712 signature) and tokenizes confirmed invoices.
contract InvoiceRegistry is AccessControl, EIP712 {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    bytes32 public constant CONFIRMATION_TYPEHASH =
        keccak256("InvoiceConfirmation(uint256 invoiceId,bytes32 invoiceHash,uint256 faceValue,uint64 dueDate)");

    uint256 public constant GRACE_PERIOD = 7 days;

    enum Status {
        None,
        Registered,
        Confirmed,
        Financed,
        Repaid,
        Defaulted,
        Cancelled
    }

    struct Invoice {
        bytes32 invoiceHash;
        address seller;
        address buyer;
        uint256 faceValue;
        uint64 dueDate;
        Status status;
    }

    InvoiceNFT public immutable nft;
    uint256 public nextInvoiceId = 1;

    mapping(uint256 => Invoice) private _invoices;
    mapping(bytes32 => bool) public hashUsed;
    mapping(address => mapping(address => bool)) public sellerAuthorizedAgent;

    error DuplicateInvoice(bytes32 invoiceHash);
    error NotAuthorizedToRegister();
    error InvalidInvoice();
    error InvalidStatus(uint256 invoiceId, Status status);
    error NotBuyer();
    error NotSeller();
    error InvalidBuyerSignature();
    error GracePeriodNotOver();

    event AgentAuthorizationSet(address indexed seller, address indexed agent, bool authorized);
    event InvoiceRegistered(
        uint256 indexed invoiceId,
        bytes32 indexed invoiceHash,
        address indexed seller,
        address buyer,
        uint256 faceValue,
        uint64 dueDate,
        address registeredBy
    );
    event InvoiceConfirmed(uint256 indexed invoiceId, address indexed buyer, bool viaSignature);
    event InvoiceFinanced(uint256 indexed invoiceId);
    event InvoiceRepaid(uint256 indexed invoiceId);
    event InvoiceDefaulted(uint256 indexed invoiceId);
    event InvoiceCancelled(uint256 indexed invoiceId);

    constructor(address admin, InvoiceNFT nft_) EIP712("CashPilot InvoiceRegistry", "1") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        nft = nft_;
    }

    // ----------------------------------------------------------------- seller / agent

    /// @notice Seller authorizes (or revokes) an agent to register invoices on its behalf.
    function setAuthorizedAgent(address agent, bool authorized) external {
        sellerAuthorizedAgent[msg.sender][agent] = authorized;
        emit AgentAuthorizationSet(msg.sender, agent, authorized);
    }

    /// @notice Registers an invoice. invoiceHash = keccak256(abi.encode(sellerTaxId, buyerTaxId,
    ///         invoiceNumber, faceValue, dueDate)), computed off-chain.
    function registerInvoice(bytes32 invoiceHash, address seller, address buyer, uint256 faceValue, uint64 dueDate)
        external
        returns (uint256 invoiceId)
    {
        bool isSeller = msg.sender == seller;
        bool isAuthorizedAgent = hasRole(PROPOSER_ROLE, msg.sender) && sellerAuthorizedAgent[seller][msg.sender];
        if (!isSeller && !isAuthorizedAgent) revert NotAuthorizedToRegister();
        if (
            invoiceHash == bytes32(0) || seller == address(0) || buyer == address(0) || buyer == seller
                || faceValue == 0 || dueDate <= block.timestamp
        ) revert InvalidInvoice();
        if (hashUsed[invoiceHash]) revert DuplicateInvoice(invoiceHash);

        hashUsed[invoiceHash] = true;
        invoiceId = nextInvoiceId++;
        _invoices[invoiceId] = Invoice(invoiceHash, seller, buyer, faceValue, dueDate, Status.Registered);
        emit InvoiceRegistered(invoiceId, invoiceHash, seller, buyer, faceValue, dueDate, msg.sender);
    }

    /// @notice Seller cancels an invoice that has not been financed yet. The hash stays used.
    function cancel(uint256 invoiceId) external {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.seller) revert NotSeller();
        Status s = inv.status;
        if (s != Status.Registered && s != Status.Confirmed) revert InvalidStatus(invoiceId, s);
        inv.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId);
        if (s == Status.Confirmed) nft.burn(invoiceId);
    }

    // ----------------------------------------------------------------- buyer confirmation

    function confirmByBuyer(uint256 invoiceId) external {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.buyer) revert NotBuyer();
        _confirm(invoiceId, inv, false);
    }

    /// @notice Anyone may relay a buyer's EIP-712 InvoiceConfirmation signature.
    function confirmByBuyerWithSig(uint256 invoiceId, bytes calldata signature) external {
        Invoice storage inv = _invoices[invoiceId];
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(confirmationDigest(invoiceId), signature);
        if (err != ECDSA.RecoverError.NoError || signer == address(0) || signer != inv.buyer) {
            revert InvalidBuyerSignature();
        }
        _confirm(invoiceId, inv, true);
    }

    function confirmationDigest(uint256 invoiceId) public view returns (bytes32) {
        Invoice storage inv = _invoices[invoiceId];
        return _hashTypedDataV4(
            keccak256(abi.encode(CONFIRMATION_TYPEHASH, invoiceId, inv.invoiceHash, inv.faceValue, inv.dueDate))
        );
    }

    function _confirm(uint256 invoiceId, Invoice storage inv, bool viaSignature) private {
        if (inv.status != Status.Registered) revert InvalidStatus(invoiceId, inv.status);
        inv.status = Status.Confirmed;
        emit InvoiceConfirmed(invoiceId, inv.buyer, viaSignature);
        nft.mint(inv.seller, invoiceId);
    }

    // ----------------------------------------------------------------- lifecycle (contracts only)

    function setFinanced(uint256 invoiceId) external onlyRole(CONTROLLER_ROLE) {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.status != Status.Confirmed) revert InvalidStatus(invoiceId, inv.status);
        inv.status = Status.Financed;
        emit InvoiceFinanced(invoiceId);
    }

    /// @dev Defaulted invoices can still be repaid late (recovery path).
    function setRepaid(uint256 invoiceId) external onlyRole(ESCROW_ROLE) {
        Invoice storage inv = _invoices[invoiceId];
        Status s = inv.status;
        if (s != Status.Confirmed && s != Status.Financed && s != Status.Defaulted) {
            revert InvalidStatus(invoiceId, s);
        }
        inv.status = Status.Repaid;
        emit InvoiceRepaid(invoiceId);
    }

    /// @notice Anyone can flag a financed invoice as defaulted once the grace period has passed.
    function markDefaulted(uint256 invoiceId) external {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.status != Status.Financed) revert InvalidStatus(invoiceId, inv.status);
        if (block.timestamp <= uint256(inv.dueDate) + GRACE_PERIOD) revert GracePeriodNotOver();
        inv.status = Status.Defaulted;
        emit InvoiceDefaulted(invoiceId);
    }

    // ----------------------------------------------------------------- views

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return _invoices[invoiceId];
    }

    function statusOf(uint256 invoiceId) external view returns (Status) {
        return _invoices[invoiceId].status;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
