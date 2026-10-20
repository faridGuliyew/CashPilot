// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title InvoiceNFT
/// @notice One non-transferable token per buyer-confirmed invoice (tokenId == invoiceId).
/// @dev The only transfer allowed is seller -> LendingPool, executed by the FinancingController
///      when an advance is approved. Tokens are minted on confirmation and burned on repayment/cancel.
contract InvoiceNFT is ERC721, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    address public lendingPool;

    error NonTransferable();
    error ZeroAddress();

    event LendingPoolSet(address indexed pool);
    event LockedToPool(uint256 indexed tokenId, address indexed pool);

    constructor(address admin) ERC721("CashPilot Invoice", "CPINV") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setLendingPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pool == address(0)) revert ZeroAddress();
        lendingPool = pool;
        emit LendingPoolSet(pool);
    }

    function mint(address to, uint256 tokenId) external onlyRole(MINTER_ROLE) {
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyRole(BURNER_ROLE) {
        _burn(tokenId);
    }

    /// @notice Moves the invoice token from the seller into the LendingPool on financing.
    function lockToPool(uint256 tokenId) external onlyRole(CONTROLLER_ROLE) {
        if (lendingPool == address(0)) revert ZeroAddress();
        _update(lendingPool, tokenId, address(0));
        emit LockedToPool(tokenId, lendingPool);
    }

    /// @dev Blocks every owner-to-owner transfer except controller-driven seller -> pool.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            if (!(to == lendingPool && hasRole(CONTROLLER_ROLE, msg.sender))) revert NonTransferable();
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
