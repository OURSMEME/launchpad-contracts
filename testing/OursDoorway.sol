// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title OursDoorway
 * @notice Cross-chain liquidity migration doorway between Robinhood Chain and Solana.
 *
 * @dev
 * This contract is an architectural reference implementation for the Ours Doorway.
 * It models the lifecycle of liquidity migration requests between:
 *
 *      Solana <-> Ours Doorway <-> Robinhood Chain
 *
 * The actual Solana settlement layer is represented by an off-chain relayer /
 * attestation network. This contract is intentionally simplified and is not
 * intended to hold production funds without a complete bridge security model.
 *
 * Ours Doorway is designed around the same modular philosophy used throughout
 * the Ours architecture:
 *
 *  - explicit lifecycle state
 *  - permissioned settlement only at the execution boundary
 *  - nonce-based replay protection
 *  - guardian attestations
 *  - delayed cancellation
 *  - isolated vault accounting
 *  - deterministic migration identifiers
 */

contract OursDoorway {

    // =============================================================
    //                            TYPES
    // =============================================================

    enum MigrationDirection {
        SOLANA_TO_ROBINHOOD,
        ROBINHOOD_TO_SOLANA
    }

    enum MigrationStatus {
        NONE,
        REQUESTED,
        ATTESTED,
        EXECUTING,
        COMPLETED,
        CANCELLED,
        FAILED
    }

    struct Migration {
        bytes32 id;

        MigrationDirection direction;
        MigrationStatus status;

        address initiator;

        // Robinhood-side token.
        address robinhoodToken;

        // Token mint represented as a 32-byte Solana public key.
        bytes32 solanaMint;

        // Destination identifier on the remote chain.
        bytes32 destination;

        uint256 amount;
        uint256 minAmountOut;

        uint256 nonce;
        uint256 createdAt;
        uint256 completedAt;

        bytes32 sourceTxHash;
        bytes32 destinationTxHash;

        uint256 fee;
    }

    struct Attestation {
        bytes32 migrationId;
        bytes32 sourceTxHash;
        uint256 amount;
        uint256 timestamp;
        uint256 nonce;
    }

    // =============================================================
    //                         CONFIGURATION
    // =============================================================

    uint256 public constant MAX_FEE_BPS = 100; // 1%

    uint256 public constant ATTESTATION_DELAY = 3 minutes;

    uint256 public constant CANCELLATION_DELAY = 30 minutes;

    address public owner;

    address public treasury;

    address public relayer;

    address public guardian;

    uint256 public migrationNonce;

    uint256 public migrationFeeBps = 25; // 0.25%

    bool public doorwayActive = true;

    // =============================================================
    //                            STORAGE
    // =============================================================

    mapping(bytes32 => Migration) public migrations;

    mapping(bytes32 => bool) public usedSourceTransactions;

    mapping(bytes32 => bool) public processedAttestations;

    mapping(address => bool) public supportedRobinhoodTokens;

    mapping(bytes32 => bool) public supportedSolanaMints;

    mapping(address => uint256) public pendingFees;

    mapping(address => uint256) public tokenLiquidity;

    mapping(bytes32 => uint256) public solanaLiquidity;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event MigrationRequested(
        bytes32 indexed migrationId,
        MigrationDirection indexed direction,
        address indexed initiator,
        address robinhoodToken,
        bytes32 solanaMint,
        bytes32 destination,
        uint256 amount,
        uint256 fee,
        uint256 nonce
    );

    event MigrationAttested(
        bytes32 indexed migrationId,
        bytes32 indexed sourceTxHash,
        uint256 amount,
        uint256 timestamp
    );

    event MigrationExecutionStarted(
        bytes32 indexed migrationId
    );

    event MigrationCompleted(
        bytes32 indexed migrationId,
        bytes32 indexed destinationTxHash,
        uint256 amount
    );

    event MigrationCancelled(
        bytes32 indexed migrationId
    );

    event TokenSupportUpdated(
        address indexed token,
        bool supported
    );

    event SolanaMintSupportUpdated(
        bytes32 indexed mint,
        bool supported
    );

    event RelayerUpdated(
        address indexed oldRelayer,
        address indexed newRelayer
    );

    event GuardianUpdated(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    event FeeUpdated(
        uint256 oldFeeBps,
        uint256 newFeeBps
    );

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "OursDoorway: not owner");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "OursDoorway: not relayer");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "OursDoorway: not guardian");
        _;
    }

    modifier doorwayOpen() {
        require(doorwayActive, "OursDoorway: paused");
        _;
    }

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(
        address _treasury,
        address _relayer,
        address _guardian
    ) {
        owner = msg.sender;

        treasury = _treasury;
        relayer = _relayer;
        guardian = _guardian;
    }

    // =============================================================
    //                    ROBINHOOD -> SOLANA
    // =============================================================

    /**
     * @notice Locks Robinhood-side liquidity and creates a Solana migration.
     *
     * The doorway records the Robinhood token and the destination Solana mint.
     * A remote relayer observes the emitted event and prepares the Solana-side
     * settlement.
     */
    function migrateToSolana(
        address token,
        bytes32 solanaMint,
        bytes32 solanaRecipient,
        uint256 amount,
        uint256 minAmountOut
    )
        external
        doorwayOpen
        returns (bytes32 migrationId)
    {
        require(
            supportedRobinhoodTokens[token],
            "OursDoorway: token unsupported"
        );

        require(
            supportedSolanaMints[solanaMint],
            "OursDoorway: mint unsupported"
        );

        require(amount > 0, "OursDoorway: zero amount");

        uint256 fee = (amount * migrationFeeBps) / 10_000;
        uint256 netAmount = amount - fee;

        migrationNonce++;

        migrationId = keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                msg.sender,
                token,
                solanaMint,
                solanaRecipient,
                amount,
                migrationNonce
            )
        );

        migrations[migrationId] = Migration({
            id: migrationId,
            direction: MigrationDirection.ROBINHOOD_TO_SOLANA,
            status: MigrationStatus.REQUESTED,
            initiator: msg.sender,
            robinhoodToken: token,
            solanaMint: solanaMint,
            destination: solanaRecipient,
            amount: netAmount,
            minAmountOut: minAmountOut,
            nonce: migrationNonce,
            createdAt: block.timestamp,
            completedAt: 0,
            sourceTxHash: bytes32(0),
            destinationTxHash: bytes32(0),
            fee: fee
        });

        pendingFees[token] += fee;
        tokenLiquidity[token] += netAmount;

        emit MigrationRequested(
            migrationId,
            MigrationDirection.ROBINHOOD_TO_SOLANA,
            msg.sender,
            token,
            solanaMint,
            solanaRecipient,
            netAmount,
            fee,
            migrationNonce
        );
    }

    // =============================================================
    //                    SOLANA -> ROBINHOOD
    // =============================================================

    /**
     * @notice Creates a migration request originating from Solana.
     *
     * In production, the relayer would only call this after observing and
     * validating the Solana source transaction.
     */
    function requestFromSolana(
        bytes32 solanaMint,
        bytes32 solanaSender,
        address robinhoodToken,
        address robinhoodRecipient,
        uint256 amount,
        uint256 sourceNonce,
        bytes32 sourceTxHash
    )
        external
        onlyRelayer
        doorwayOpen
        returns (bytes32 migrationId)
    {
        require(
            supportedSolanaMints[solanaMint],
            "OursDoorway: mint unsupported"
        );

        require(
            supportedRobinhoodTokens[robinhoodToken],
            "OursDoorway: token unsupported"
        );

        require(
            !usedSourceTransactions[sourceTxHash],
            "OursDoorway: source tx used"
        );

        require(amount > 0, "OursDoorway: zero amount");

        usedSourceTransactions[sourceTxHash] = true;

        uint256 fee = (amount * migrationFeeBps) / 10_000;
        uint256 netAmount = amount - fee;

        migrationNonce++;

        migrationId = keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                solanaMint,
                solanaSender,
                robinhoodRecipient,
                sourceTxHash,
                sourceNonce,
                migrationNonce
            )
        );

        migrations[migrationId] = Migration({
            id: migrationId,
            direction: MigrationDirection.SOLANA_TO_ROBINHOOD,
            status: MigrationStatus.REQUESTED,
            initiator: robinhoodRecipient,
            robinhoodToken: robinhoodToken,
            solanaMint: solanaMint,
            destination: bytes32(uint256(uint160(robinhoodRecipient))),
            amount: netAmount,
            minAmountOut: netAmount,
            nonce: migrationNonce,
            createdAt: block.timestamp,
            completedAt: 0,
            sourceTxHash: sourceTxHash,
            destinationTxHash: bytes32(0),
            fee: fee
        });

        pendingFees[robinhoodToken] += fee;

        emit MigrationRequested(
            migrationId,
            MigrationDirection.SOLANA_TO_ROBINHOOD,
            robinhoodRecipient,
            robinhoodToken,
            solanaMint,
            bytes32(uint256(uint160(robinhoodRecipient))),
            netAmount,
            fee,
            migrationNonce
        );
    }

    // =============================================================
    //                         ATTESTATION
    // =============================================================

    /**
     * @notice Guardian attestation for a cross-chain migration.
     *
     * This represents the security boundary between the EVM contract and the
     * Solana settlement layer.
     */
    function attestMigration(
        Attestation calldata attestation
    )
        external
        onlyGuardian
    {
        Migration storage migration = migrations[attestation.migrationId];

        require(
            migration.status == MigrationStatus.REQUESTED,
            "OursDoorway: invalid status"
        );

        require(
            attestation.amount == migration.amount,
            "OursDoorway: amount mismatch"
        );

        require(
            attestation.sourceTxHash == migration.sourceTxHash ||
            migration.sourceTxHash == bytes32(0),
            "OursDoorway: source mismatch"
        );

        require(
            !processedAttestations[attestation.sourceTxHash],
            "OursDoorway: already attested"
        );

        processedAttestations[attestation.sourceTxHash] = true;

        migration.status = MigrationStatus.ATTESTED;

        emit MigrationAttested(
            attestation.migrationId,
            attestation.sourceTxHash,
            attestation.amount,
            block.timestamp
        );
    }

    // =============================================================
    //                         EXECUTION
    // =============================================================

    /**
     * @notice Executes an attested migration.
     *
     * Actual token mint/burn/escrow mechanics would be delegated to a
     * token adapter in a production deployment.
     */
    function executeMigration(
        bytes32 migrationId,
        bytes32 destinationTxHash
    )
        external
        onlyRelayer
        doorwayOpen
    {
        Migration storage migration = migrations[migrationId];

        require(
            migration.status == MigrationStatus.ATTESTED,
            "OursDoorway: not attested"
        );

        migration.status = MigrationStatus.EXECUTING;

        emit MigrationExecutionStarted(migrationId);

        // ---------------------------------------------------------
        // Reference implementation:
        //
        // ROBINHOOD -> SOLANA
        //     Locked liquidity remains accounted for on RH.
        //     Relayer releases equivalent liquidity on Solana.
        //
        // SOLANA -> ROBINHOOD
        //     Solana source liquidity is considered burned/locked.
        //     Equivalent RH representation is released.
        //
        // A production implementation would invoke a token adapter here.
        // ---------------------------------------------------------

        migration.destinationTxHash = destinationTxHash;
        migration.completedAt = block.timestamp;

        migration.status = MigrationStatus.COMPLETED;

        emit MigrationCompleted(
            migrationId,
            destinationTxHash,
            migration.amount
        );
    }

    // =============================================================
    //                         CANCELLATION
    // =============================================================

    /**
     * @notice Cancels an unexecuted migration after the safety delay.
     */
    function cancelMigration(
        bytes32 migrationId
    )
        external
    {
        Migration storage migration = migrations[migrationId];

        require(
            migration.initiator == msg.sender ||
            msg.sender == guardian,
            "OursDoorway: not authorized"
        );

        require(
            migration.status == MigrationStatus.REQUESTED ||
            migration.status == MigrationStatus.ATTESTED,
            "OursDoorway: cannot cancel"
        );

        require(
            block.timestamp >=
                migration.createdAt + CANCELLATION_DELAY,
            "OursDoorway: cancellation locked"
        );

        migration.status = MigrationStatus.CANCELLED;

        emit MigrationCancelled(migrationId);
    }

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    function getMigration(
        bytes32 migrationId
    )
        external
        view
        returns (Migration memory)
    {
        return migrations[migrationId];
    }

    function migrationExists(
        bytes32 migrationId
    )
        external
        view
        returns (bool)
    {
        return migrations[migrationId].status != MigrationStatus.NONE;
    }

    function calculateFee(
        uint256 amount
    )
        public
        view
        returns (uint256)
    {
        return (amount * migrationFeeBps) / 10_000;
    }

    function calculateNetAmount(
        uint256 amount
    )
        external
        view
        returns (uint256)
    {
        return amount - calculateFee(amount);
    }

    // =============================================================
    //                       ADMINISTRATION
    // =============================================================

    function setRobinhoodToken(
        address token,
        bool enabled
    )
        external
        onlyOwner
    {
        supportedRobinhoodTokens[token] = enabled;

        emit TokenSupportUpdated(token, enabled);
    }

    function setSolanaMint(
        bytes32 mint,
        bool enabled
    )
        external
        onlyOwner
    {
        supportedSolanaMints[mint] = enabled;

        emit SolanaMintSupportUpdated(mint, enabled);
    }

    function setRelayer(
        address newRelayer
    )
        external
        onlyOwner
    {
        emit RelayerUpdated(relayer, newRelayer);

        relayer = newRelayer;
    }

    function setGuardian(
        address newGuardian
    )
        external
        onlyOwner
    {
        emit GuardianUpdated(guardian, newGuardian);

        guardian = newGuardian;
    }

    function setFee(
        uint256 newFeeBps
    )
        external
        onlyOwner
    {
        require(
            newFeeBps <= MAX_FEE_BPS,
            "OursDoorway: fee too high"
        );

        emit FeeUpdated(
            migrationFeeBps,
            newFeeBps
        );

        migrationFeeBps = newFeeBps;
    }

    function setDoorwayActive(
        bool active
    )
        external
        onlyOwner
    {
        doorwayActive = active;
    }

    function transferOwnership(
        address newOwner
    )
        external
        onlyOwner
    {
        require(
            newOwner != address(0),
            "OursDoorway: zero owner"
        );

        owner = newOwner;
    }
}
