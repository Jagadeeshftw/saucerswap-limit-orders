// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHederaTokenService } from "../../contracts/interfaces/IHederaTokenService.sol";

/// @notice HTS-style NFT collection: ERC-721 facade reads plus transfers driven by MockHts.
contract MockNftCollection {
    address public immutable hts;
    mapping(uint256 serial => address) public ownerOfSerial;
    mapping(address account => bool) public associated;
    uint256 public totalSupply;
    int64 internal _nextSerial = 1;

    error NotHts();

    constructor(address hts_, address treasury) {
        hts = hts_;
        associated[treasury] = true;
    }

    modifier onlyHts() {
        if (msg.sender != hts) revert NotHts();
        _;
    }

    function ownerOf(uint256 serial) external view returns (address) {
        return ownerOfSerial[serial];
    }

    /// @notice HIP-719 style association, callable by the account itself.
    function associate() external {
        associated[msg.sender] = true;
    }

    /// @notice Holder-initiated transfer, as a wallet would do through the ERC-721 facade.
    function transferFrom(address from, address to, uint256 serial) external {
        require(msg.sender == from && ownerOfSerial[serial] == from, "not owner");
        require(associated[to], "TOKEN_NOT_ASSOCIATED_TO_ACCOUNT");
        ownerOfSerial[serial] = to;
    }

    function mint(address treasury) external onlyHts returns (int64 serial) {
        serial = _nextSerial++;
        ownerOfSerial[uint256(uint64(serial))] = treasury;
        totalSupply++;
    }

    function move(address from, address to, uint256 serial) external onlyHts returns (bool) {
        if (ownerOfSerial[serial] != from || !associated[to]) return false;
        ownerOfSerial[serial] = to;
        return true;
    }

    function remove(address from, uint256 serial) external onlyHts returns (bool) {
        if (ownerOfSerial[serial] != from) return false;
        delete ownerOfSerial[serial];
        totalSupply--;
        return true;
    }

    function setAssociated(address account, bool value) external {
        associated[account] = value;
    }
}

/// @notice Stand-in for the HTS system contract at 0x167, covering the calls OrderVault makes.
contract MockHts {
    int64 internal constant SUCCESS = 22;
    int64 internal constant INVALID_NFT_ID = 226;
    int64 internal constant TOKEN_NOT_ASSOCIATED = 184;
    int64 internal constant INVALID_TREASURY = 167;

    mapping(address collection => address treasury) public treasuryOf;
    mapping(address account => mapping(address token => bool)) public associations;
    int64 public forcedCreateCode;
    int64 public forcedAssociateCode;
    int64 public forcedMintCode;
    int64 public forcedWipeCode;
    uint256 public lastCreateValue;

    function forceCreateCode(int64 code) external {
        forcedCreateCode = code;
    }

    function forceAssociateCode(int64 code) external {
        forcedAssociateCode = code;
    }

    function forceMintCode(int64 code) external {
        forcedMintCode = code;
    }

    function forceWipeCode(int64 code) external {
        forcedWipeCode = code;
    }

    function createNonFungibleToken(IHederaTokenService.HederaToken memory token)
        external
        payable
        returns (int64, address)
    {
        if (forcedCreateCode != 0) return (forcedCreateCode, address(0));
        lastCreateValue = msg.value;
        MockNftCollection collection = new MockNftCollection(address(this), token.treasury);
        treasuryOf[address(collection)] = token.treasury;
        return (SUCCESS, address(collection));
    }

    function mintToken(address token, int64, bytes[] memory) external returns (int64, int64, int64[] memory serials) {
        serials = new int64[](1);
        if (forcedMintCode != 0) return (forcedMintCode, 0, serials);
        serials[0] = MockNftCollection(token).mint(treasuryOf[token]);
        return (SUCCESS, int64(uint64(MockNftCollection(token).totalSupply())), serials);
    }

    function transferNFT(address token, address sender, address recipient, int64 serial) external returns (int64) {
        bool ok = MockNftCollection(token).move(sender, recipient, uint256(uint64(serial)));
        return ok ? SUCCESS : TOKEN_NOT_ASSOCIATED;
    }

    function wipeTokenAccountNFT(address token, address account, int64[] memory serials) external returns (int64) {
        if (forcedWipeCode != 0) return forcedWipeCode;
        if (account == treasuryOf[token]) return INVALID_TREASURY;
        return MockNftCollection(token).remove(account, uint256(uint64(serials[0]))) ? SUCCESS : INVALID_NFT_ID;
    }

    function burnToken(address token, int64, int64[] memory serials) external returns (int64, int64) {
        bool ok = MockNftCollection(token).remove(treasuryOf[token], uint256(uint64(serials[0])));
        return (ok ? SUCCESS : INVALID_NFT_ID, int64(uint64(MockNftCollection(token).totalSupply())));
    }

    function associateToken(address account, address token) external returns (int64) {
        if (forcedAssociateCode != 0) return forcedAssociateCode;
        if (associations[account][token]) return 194;
        associations[account][token] = true;
        return SUCCESS;
    }
}

/// @notice Stand-in for the Hedera Schedule Service at 0x16b. Tests execute schedules with `vm.prank(vault)`.
contract MockHss {
    struct Scheduled {
        address to;
        uint256 expiry;
        uint256 gasLimit;
        bytes callData;
    }

    Scheduled[] public scheduled;
    uint256 public busyUntil;
    int64 public forcedCode;
    bool public noCapacity;

    function forceCode(int64 code) external {
        forcedCode = code;
    }

    function setNoCapacity(bool value) external {
        noCapacity = value;
    }

    function scheduleCall(address to, uint256 expiry, uint256 gasLimit, uint64, bytes memory callData)
        external
        returns (int64, address)
    {
        if (forcedCode != 0) return (forcedCode, address(0));
        scheduled.push(Scheduled({ to: to, expiry: expiry, gasLimit: gasLimit, callData: callData }));
        return (22, address(uint160(0x5c4ed000 + scheduled.length)));
    }

    function hasScheduleCapacity(uint256 expiry, uint256) external view returns (bool) {
        return !noCapacity && expiry > block.timestamp && expiry >= busyUntil;
    }

    /// @notice Every second before `until` is full, as when many contracts schedule at once.
    function setBusyUntil(uint256 until) external {
        busyUntil = until;
    }

    function count() external view returns (uint256) {
        return scheduled.length;
    }

    function job(uint256 index) external view returns (Scheduled memory) {
        return scheduled[index];
    }

    function last() external view returns (Scheduled memory) {
        return scheduled[scheduled.length - 1];
    }
}

/// @notice Stand-in for the exchange-rate system contract at 0x168, fixed at the testnet rate seen on 2026-09-29.
contract MockExchangeRate {
    uint256 internal constant CENT_EQUIVALENT = 231_199;
    uint256 internal constant HBAR_EQUIVALENT = 30_000;

    function tinycentsToTinybars(uint256 tinycents) external pure returns (uint256) {
        return tinycents * HBAR_EQUIVALENT / CENT_EQUIVALENT;
    }

    function tinybarsToTinycents(uint256 tinybars) external pure returns (uint256) {
        return tinybars * CENT_EQUIVALENT / HBAR_EQUIVALENT;
    }
}
