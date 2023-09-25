// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/AddressUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/BeaconChainProofs.sol";
import "../libraries/BytesLib.sol";
import "../libraries/Endian.sol";

import "../interfaces/IETHPOSDeposit.sol";
import "../interfaces/IEigenPodManager.sol";
import "../interfaces/IEigenPod.sol";
import "../interfaces/IDelayedWithdrawalRouter.sol";
import "../interfaces/IPausable.sol";

import "./EigenPodPausingConstants.sol";

/**
 * @title The implementation contract used for restaking beacon chain ETH on EigenLayer 
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @notice The main functionalities are:
 * - creating new ETH validators with their withdrawal credentials pointed to this contract
 * - proving from beacon chain state roots that withdrawal credentials are pointed to this contract
 * - proving from beacon chain state roots the balances of ETH validators with their withdrawal credentials
 *   pointed to this contract
 * - updating aggregate balances in the EigenPodManager
 * - withdrawing eth when withdrawals are initiated
 * @dev Note that all beacon chain balances are stored as gwei within the beacon chain datastructures. We choose
 *   to account balances in terms of gwei in the EigenPod contract and convert to wei when making calls to other contracts
 */
contract EigenPod is IEigenPod, Initializable, ReentrancyGuardUpgradeable, EigenPodPausingConstants {
    using BytesLib for bytes;
    using SafeERC20 for IERC20;

    // CONSTANTS + IMMUTABLES
    // @notice Internal constant used in calculations, since the beacon chain stores balances in Gwei rather than wei
    uint256 internal constant GWEI_TO_WEI = 1e9;

    /// @notice Maximum "staleness" of a Beacon Chain state root against which `verifyBalanceUpdate` or `verifyWithdrawalCredentials` may be proven.
    uint256 internal constant VERIFY_BALANCE_UPDATE_WINDOW_SECONDS = 4.5 hours;

    /// @notice The number of seconds in a slot in the beacon chain
    uint256 internal constant SECONDS_PER_SLOT = 12;

    /// @notice This is the beacon chain deposit contract
    IETHPOSDeposit public immutable ethPOS;

    /// @notice Contract used for withdrawal routing, to provide an extra "safety net" mechanism
    IDelayedWithdrawalRouter public immutable delayedWithdrawalRouter;

    /// @notice The single EigenPodManager for EigenLayer
    IEigenPodManager public immutable eigenPodManager;

    ///@notice The maximum amount of ETH, in gwei, a validator can have staked in the beacon chain
    uint64 public immutable MAX_VALIDATOR_BALANCE_GWEI;

    /** 
    * @notice The value used in our effective restaked balance calculation, to set the 
    * amount by which to underestimate the validator's effective balance.
    */
    uint64 public immutable RESTAKED_BALANCE_OFFSET_GWEI;

    /// @notice This is the genesis time of the beacon state, to help us calculate conversions between slot and timestamp
    uint64 public immutable GENESIS_TIME;

    // STORAGE VARIABLES
    /// @notice The owner of this EigenPod
    address public podOwner;

    /**
     * @notice The latest block number at which the pod owner withdrew the balance of the pod.
     * @dev This variable is only updated when the `withdraw` function is called, which can only occur before `hasRestaked` is set to true for this pod.
     * Proofs for this pod are only valid against Beacon Chain state roots corresponding to blocks after the stored `mostRecentWithdrawalTimestamp`.
     */
    uint64 public mostRecentWithdrawalTimestamp;

    /// @notice the amount of execution layer ETH in this contract that is staked in EigenLayer (i.e. withdrawn from the Beacon Chain but not from EigenLayer), 
    uint64 public withdrawableRestakedExecutionLayerGwei;

    /// @notice an indicator of whether or not the podOwner has ever "fully restaked" by successfully calling `verifyCorrectWithdrawalCredentials`.
    bool public hasRestaked;

    /// @notice This is a mapping of validatorPubkeyHash to timestamp to whether or not they have proven a withdrawal for that timestamp
    mapping(bytes32 => mapping(uint64 => bool)) public provenWithdrawal;

    /// @notice This is a mapping that tracks a validator's information by their pubkey hash
    mapping(bytes32 => ValidatorInfo) internal _validatorPubkeyHashToInfo;

    /// @notice This variable tracks any ETH deposited into this contract via the `receive` fallback function
    uint256 public nonBeaconChainETHBalanceWei;

    /// @notice Emitted when an ETH validator stakes via this eigenPod
    event EigenPodStaked(bytes pubkey);

    /// @notice Emitted when an ETH validator's withdrawal credentials are successfully verified to be pointed to this eigenPod
    event ValidatorRestaked(uint40 validatorIndex, bytes32 validatorPubkeyHash, bytes validatorPubkey);

    /// @notice Emitted when an ETH validator's  balance is proven to be updated.  Here newValidatorBalanceGwei
    //  is the validator's balance that is credited on EigenLayer.
    event ValidatorBalanceUpdated(uint40 validatorIndex, uint64 balanceTimestamp, uint64 newValidatorBalanceGwei);
    
    /// @notice Emitted when an ETH validator is prove to have withdrawn from the beacon chain
    event FullWithdrawalRedeemed(uint40 validatorIndex, uint64 withdrawalTimestamp, address indexed recipient, uint64 withdrawalAmountGwei);

    /// @notice Emitted when a partial withdrawal claim is successfully redeemed
    event PartialWithdrawalRedeemed(uint40 validatorIndex, uint64 withdrawalTimestamp, address indexed recipient, uint64 partialWithdrawalAmountGwei);

    /// @notice Emitted when restaked beacon chain ETH is withdrawn from the eigenPod.
    event RestakedBeaconChainETHWithdrawn(address indexed recipient, uint256 amount);

    /// @notice Emitted when podOwner enables restaking
    event RestakingActivated(address indexed podOwner);

    /// @notice Emitted when ETH is received via the `receive` fallback
    event NonBeaconChainETHReceived(uint256 amountReceived);    

    /// @notice Emitted when ETH that was previously received via the `receive` fallback is withdrawn
    event NonBeaconChainETHWithdrawn(address indexed recipient, uint256 amountWithdrawn);    

    modifier onlyEigenPodManager {
        require(msg.sender == address(eigenPodManager), "EigenPod.onlyEigenPodManager: not eigenPodManager");
        _;
    }

    modifier onlyEigenPodOwner {
        require(msg.sender == podOwner, "EigenPod.onlyEigenPodOwner: not podOwner");
        _;
    }

    modifier onlyNotFrozen {
        require(!eigenPodManager.slasher().isFrozen(podOwner), "EigenPod.onlyNotFrozen: pod owner is frozen");
        _;
    }

    modifier hasNeverRestaked {
        require(!hasRestaked, "EigenPod.hasNeverRestaked: restaking is enabled");
        _;
    }

    /// @notice checks that hasRestaked is set to true by calling activateRestaking()
    modifier hasEnabledRestaking {
        require(hasRestaked, "EigenPod.hasEnabledRestaking: restaking is not enabled");
        _;
    }

    /// @notice Checks that `timestamp` is strictly greater than the value stored in `mostRecentWithdrawalTimestamp`
    modifier proofIsForValidTimestamp(uint64 timestamp) {
        require(timestamp > mostRecentWithdrawalTimestamp,
            "EigenPod.proofIsForValidTimestamp: beacon chain proof must be for timestamp after mostRecentWithdrawalTimestamp");
        _;
    }


    /**
     * @notice Based on 'Pausable' code, but uses the storage of the EigenPodManager instead of this contract. This construction
     * is necessary for enabling pausing all EigenPods at the same time (due to EigenPods being Beacon Proxies).
     * Modifier throws if the `indexed`th bit of `_paused` in the EigenPodManager is 1, i.e. if the `index`th pause switch is flipped.
     */
    modifier onlyWhenNotPaused(uint8 index) {
        require(!IPausable(address(eigenPodManager)).paused(index), "EigenPod.onlyWhenNotPaused: index is paused in EigenPodManager");
        _;
    }

    constructor(
        IETHPOSDeposit _ethPOS,
        IDelayedWithdrawalRouter _delayedWithdrawalRouter,
        IEigenPodManager _eigenPodManager,
        uint64 _MAX_VALIDATOR_BALANCE_GWEI,
        uint64 _RESTAKED_BALANCE_OFFSET_GWEI,
        uint64 _GENESIS_TIME
    ) {
        ethPOS = _ethPOS;
        delayedWithdrawalRouter = _delayedWithdrawalRouter;
        eigenPodManager = _eigenPodManager;
        MAX_VALIDATOR_BALANCE_GWEI = _MAX_VALIDATOR_BALANCE_GWEI;
        RESTAKED_BALANCE_OFFSET_GWEI = _RESTAKED_BALANCE_OFFSET_GWEI;
        GENESIS_TIME = _GENESIS_TIME;
        _disableInitializers();
    }

    /// @notice Used to initialize the pointers to addresses crucial to the pod's functionality. Called on construction by the EigenPodManager.
    function initialize(address _podOwner) external initializer {
        require(_podOwner != address(0), "EigenPod.initialize: podOwner cannot be zero address");
        podOwner = _podOwner;
    }

    function validatorPubkeyHashToInfo(bytes32 validatorPubkeyHash) external view returns(ValidatorInfo memory) {
        return _validatorPubkeyHashToInfo[validatorPubkeyHash];
    }

    function validatorStatus(bytes32 pubkeyHash) external view returns (VALIDATOR_STATUS) {
        return _validatorPubkeyHashToInfo[pubkeyHash].status;
    }

    /// @notice payable fallback function that receives ether deposited to the eigenpods contract
    receive() external payable {
        nonBeaconChainETHBalanceWei += msg.value;
        emit NonBeaconChainETHReceived(msg.value);
    }

    /**
     * @notice This function records an update (either increase or decrease) in the pod's balance in the StrategyManager.  
               It also verifies a merkle proof of the validator's current beacon chain balance.  
     * @param oracleTimestamp The oracleTimestamp whose state root the `proof` will be proven against.
     *        Must be within `VERIFY_BALANCE_UPDATE_WINDOW_SECONDS` of the current block.
     * @param validatorIndex is the index of the validator being proven, refer to consensus specs 
     * @param balanceUpdateProof is the proof of the validator's balance and validatorFields in the balance tree and the balanceRoot to prove for
     *                                    the StrategyManager in case it must be removed from the list of the podOwner's strategies
     * @param validatorFields are the fields of the "Validator Container", refer to consensus specs
     * @dev For more details on the Beacon Chain spec, see: https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#validator
     */
    function verifyBalanceUpdate(
        uint64 oracleTimestamp,
        uint40 validatorIndex,
        BeaconChainProofs.BalanceUpdateProof calldata balanceUpdateProof,
        bytes32[] calldata validatorFields
    ) external onlyWhenNotPaused(PAUSED_EIGENPODS_VERIFY_BALANCE_UPDATE) {
       // ensure that the timestamp being proven against is not "too stale", i.e. that the validator's balance *recently* changed.
        require(oracleTimestamp + VERIFY_BALANCE_UPDATE_WINDOW_SECONDS >= block.timestamp,
            "EigenPod.verifyBalanceUpdate: specified timestamp is too far in past");

        bytes32 validatorPubkeyHash = validatorFields[BeaconChainProofs.VALIDATOR_PUBKEY_INDEX];

        ValidatorInfo memory validatorInfo = _validatorPubkeyHashToInfo[validatorPubkeyHash];

        // verify that the validator has been proven to have its withdrawal credentials pointed to this EigenPod, and has not yet been proven to be exited
        require(validatorInfo.status == VALIDATOR_STATUS.ACTIVE, "EigenPod.verifyBalanceUpdate: Validator not active");

        // check that the balance update is being made strictly after the previous balance update
        require(validatorInfo.mostRecentBalanceUpdateTimestamp < oracleTimestamp,
            "EigenPod.verifyBalanceUpdate: Validators balance has already been updated for this timestamp");

        {
            // verify ETH validator proof
            bytes32 latestBlockRoot = eigenPodManager.getBlockRootAtTimestamp(oracleTimestamp);

            // verify the provided state root against the oracle-provided latest block header
            BeaconChainProofs.verifyStateRootAgainstLatestBlockRoot({
                latestBlockRoot: latestBlockRoot,
                beaconStateRoot: balanceUpdateProof.beaconStateRoot,
                stateRootProof: balanceUpdateProof.stateRootProof
            });
        }

        // verify the provided ValidatorFields against the provided state root, now that it has been proven against the latest block header
        BeaconChainProofs.verifyValidatorFields({
            beaconStateRoot: balanceUpdateProof.beaconStateRoot,
            validatorFields: validatorFields,            
            validatorFieldsProof: balanceUpdateProof.validatorFieldsProof,
            validatorIndex: validatorIndex
        });
 
        // verify ETH validators current balance, which is stored in the `balances` container of the beacon state
        BeaconChainProofs.verifyValidatorBalance({
            beaconStateRoot: balanceUpdateProof.beaconStateRoot,
            balanceRoot: balanceUpdateProof.balanceRoot,
            validatorBalanceProof: balanceUpdateProof.validatorBalanceProof,
            validatorIndex: validatorIndex
        });

        // store the current restaked balance in memory, to be checked against later
        uint64 currentRestakedBalanceGwei = validatorInfo.restakedBalanceGwei;

        // deserialize the balance field from the balanceRoot and calculate the effective (pessimistic) restaked balance
        uint64 newRestakedBalanceGwei = _calculateRestakedBalanceGwei(BeaconChainProofs.getBalanceFromBalanceRoot(validatorIndex, balanceUpdateProof.balanceRoot));

        // update the balance
        validatorInfo.restakedBalanceGwei = newRestakedBalanceGwei;

        //update the most recent balance update timestamp
        validatorInfo.mostRecentBalanceUpdateTimestamp = oracleTimestamp;

        // record validatorInfo update in storage
        _validatorPubkeyHashToInfo[validatorPubkeyHash] = validatorInfo;
        

        if (newRestakedBalanceGwei != currentRestakedBalanceGwei){
            emit ValidatorBalanceUpdated(validatorIndex, oracleTimestamp, newRestakedBalanceGwei);

            int256 sharesDelta = _calculateSharesDelta({
                newAmountWei: (newRestakedBalanceGwei * GWEI_TO_WEI),
                currentAmountWei: (currentRestakedBalanceGwei * GWEI_TO_WEI)
            });
            // update shares in strategy manager
            eigenPodManager.recordBeaconChainETHBalanceUpdate(podOwner, sharesDelta);
        }
    }

    /**
     * @notice This function records full and partial withdrawals on behalf of one of the Ethereum validators for this EigenPod
     * @param oracleTimestamp is the timestamp of the oracle slot that the withdrawal is being proven against
     * @param withdrawalProofs is the information needed to check the veracity of the block numbers and withdrawals being proven
     * @param validatorFieldsProofs is the proof of the validator's fields' in the validator tree
     * @param withdrawalFields are the fields of the withdrawals being proven
     * @param validatorFields are the fields of the validators being proven
     */
    function verifyAndProcessWithdrawals(
        uint64 oracleTimestamp,
        BeaconChainProofs.WithdrawalProof[] calldata withdrawalProofs, 
        bytes[] calldata validatorFieldsProofs,
        bytes32[][] calldata validatorFields,
        bytes32[][] calldata withdrawalFields
    )
        external
        onlyWhenNotPaused(PAUSED_EIGENPODS_VERIFY_WITHDRAWAL)
        onlyNotFrozen
    {
        require(
            (validatorFields.length == validatorFieldsProofs.length) && 
            (validatorFieldsProofs.length == withdrawalProofs.length) && 
            (withdrawalProofs.length == withdrawalFields.length), "EigenPod.verifyAndProcessWithdrawals: inputs must be same length"
        );

        for (uint256 i = 0; i < withdrawalFields.length; i++) {
            _verifyAndProcessWithdrawal(oracleTimestamp, withdrawalProofs[i], validatorFieldsProofs[i], validatorFields[i], withdrawalFields[i]);
        }
    }


    /*******************************************************************************
                    EXTERNAL FUNCTIONS CALLABLE BY EIGEN POD OWNER
    *******************************************************************************/

     /**
     * @notice This function verifies that the withdrawal credentials of validator(s) owned by the podOwner are pointed to
     * this contract. It also verifies the effective balance  of the validator.  It verifies the provided proof of the ETH validator against the beacon chain state
     * root, marks the validator as 'active' in EigenLayer, and credits the restaked ETH in Eigenlayer.
     * @param oracleTimestamp is the Beacon Chain timestamp whose state root the `proof` will be proven against.
     * @param validatorIndices is the list of indices of the validators being proven, refer to consensus specs 
     * @param withdrawalCredentialProofs is an array of proofs, where each proof proves each ETH validator's balance and withdrawal credentials against a beacon chain state root
     * @param validatorFields are the fields of the "Validator Container", refer to consensus specs 
     * for details: https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#validator
     */
    function verifyWithdrawalCredentials(
        uint64 oracleTimestamp,
        uint40[] calldata validatorIndices,
        bytes[] calldata validatorPubkeys,
        BeaconChainProofs.WithdrawalCredentialProof[] calldata withdrawalCredentialProofs,
        bytes32[][] calldata validatorFields
    ) external 
        onlyEigenPodOwner
        onlyWhenNotPaused(PAUSED_EIGENPODS_VERIFY_CREDENTIALS)
        // check that the provided `oracleTimestamp` is after the `mostRecentWithdrawalTimestamp`
        proofIsForValidTimestamp(oracleTimestamp)
        // ensure that caller has previously enabled restaking by calling `activateRestaking()`
        hasEnabledRestaking
    {
        // ensure that the timestamp being proven against is not "too stale", i.e. that the validator's effective balance *recently* changed.
        require(oracleTimestamp + VERIFY_BALANCE_UPDATE_WINDOW_SECONDS >= block.timestamp,
            "EigenPod.verifyWithdrawalCredentials: specified timestamp is too far in past");

        require((validatorIndices.length == withdrawalCredentialProofs.length) && (withdrawalCredentialProofs.length == validatorFields.length) && (validatorFields.length == validatorPubkeys.length),
            "EigenPod.verifyWithdrawalCredentials: validatorIndices and proofs must be same length");
        
        uint256 totalAmountToBeRestakedWei;
        for (uint256 i = 0; i < validatorIndices.length; i++) {
            totalAmountToBeRestakedWei += _verifyWithdrawalCredentials(oracleTimestamp, validatorIndices[i], validatorPubkeys[i], withdrawalCredentialProofs[i], validatorFields[i]);
        }

         // virtually deposit for new ETH validator(s)
        eigenPodManager.restakeBeaconChainETH(podOwner, totalAmountToBeRestakedWei);
    }

    /// @notice Called by the pod owner to withdraw the nonBeaconChainETHBalanceWei
    function withdrawNonBeaconChainETHBalanceWei(address recipient, uint256 amountToWithdraw) external onlyEigenPodOwner {
        require(amountToWithdraw <= nonBeaconChainETHBalanceWei,
            "EigenPod.withdrawnonBeaconChainETHBalanceWei: amountToWithdraw is greater than nonBeaconChainETHBalanceWei");
        nonBeaconChainETHBalanceWei -= amountToWithdraw;
        emit NonBeaconChainETHWithdrawn(recipient, amountToWithdraw);
        _sendETH_AsDelayedWithdrawal(recipient, amountToWithdraw);
    }

    /// @notice called by owner of a pod to remove any ERC20s deposited in the pod
    function recoverTokens(IERC20[] memory tokenList, uint256[] memory amountsToWithdraw, address recipient) external onlyEigenPodOwner {
        require(tokenList.length == amountsToWithdraw.length, "EigenPod.recoverTokens: tokenList and amountsToWithdraw must be same length");
        for (uint256 i = 0; i < tokenList.length; i++) {
            tokenList[i].safeTransfer(recipient, amountsToWithdraw[i]);
        }
    }

    /**
     * @notice Called by the pod owner to activate restaking by withdrawing 
     * all existing ETH from the pod and preventing further withdrawals via 
     * "withdrawBeforeRestaking()"
    */ 
    function activateRestaking() external onlyWhenNotPaused(PAUSED_EIGENPODS_VERIFY_CREDENTIALS) onlyEigenPodOwner hasNeverRestaked {
        hasRestaked = true;
        _processWithdrawalBeforeRestaking(podOwner);

        emit RestakingActivated(podOwner);
    }

    /// @notice Called by the pod owner to withdraw the balance of the pod when `hasRestaked` is set to false
    function withdrawBeforeRestaking() external onlyEigenPodOwner hasNeverRestaked {
        _processWithdrawalBeforeRestaking(podOwner);
    }

    /*******************************************************************************
                    EXTERNAL FUNCTIONS CALLABLE BY EIGENPODMANAGER
    *******************************************************************************/

    /// @notice Called by EigenPodManager when the owner wants to create another ETH validator.
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot) external payable onlyEigenPodManager {
        // stake on ethpos
        require(msg.value == 32 ether, "EigenPod.stake: must initially stake for any validator with 32 ether");
        ethPOS.deposit{value : 32 ether}(pubkey, _podWithdrawalCredentials(), signature, depositDataRoot);
        emit EigenPodStaked(pubkey);
    }

    /**
     * @notice This function is called to decrement withdrawableRestakedExecutionLayerGwei when a validator queues a withdrawal.
     * @param amountWei is the amount of ETH in wei to decrement withdrawableRestakedExecutionLayerGwei by
     */
    function decrementWithdrawableRestakedExecutionLayerGwei(uint256 amountWei) external onlyEigenPodManager {
        uint64 amountGwei = uint64(amountWei / GWEI_TO_WEI);
        require(withdrawableRestakedExecutionLayerGwei >= amountGwei,
            "EigenPod.decrementWithdrawableRestakedExecutionLayerGwei: amount to decrement is greater than current withdrawableRestakedRxecutionLayerGwei balance");
        withdrawableRestakedExecutionLayerGwei -= amountGwei;
    }

    /**
     * @notice This function is called to increment withdrawableRestakedExecutionLayerGwei when a validator's withdrawal is completed.
     * @param amountWei is the amount of ETH in wei to increment withdrawableRestakedExecutionLayerGwei by
     */
    function incrementWithdrawableRestakedExecutionLayerGwei(uint256 amountWei) external onlyEigenPodManager {
        uint64 amountGwei = uint64(amountWei / GWEI_TO_WEI);
        withdrawableRestakedExecutionLayerGwei += amountGwei;
    }

    /**
     * @notice Transfers `amountWei` in ether from this contract to the specified `recipient` address
     * @notice Called by EigenPodManager to withdrawBeaconChainETH that has been added to the EigenPod's balance due to a withdrawal from the beacon chain.
     * @dev Called during withdrawal or slashing.
     */
    function withdrawRestakedBeaconChainETH(address recipient, uint256 amountWei) external onlyEigenPodManager {
        emit RestakedBeaconChainETHWithdrawn(recipient, amountWei);
        // transfer ETH from pod to `recipient` directly
        _sendETH(recipient, amountWei);
    }
    

    /*******************************************************************************
                                INTERNAL FUNCTIONS
    *******************************************************************************/
    /**
     * @notice internal function that proves an individual validator's withdrawal credentials
     * @param oracleTimestamp is the timestamp whose state root the `proof` will be proven against.
     * @param validatorIndex is the index of the validator being proven
     * @param withdrawalCredentialProof is the bytes that prove the ETH validator's  withdrawal credentials against a beacon chain state root
     * @param validatorFields are the fields of the "Validator Container", refer to consensus specs
     */
    function _verifyWithdrawalCredentials(
        uint64 oracleTimestamp,
        uint40 validatorIndex,
        bytes memory validatorPubkey,
        BeaconChainProofs.WithdrawalCredentialProof calldata withdrawalCredentialProof,
        bytes32[] calldata validatorFields
    )
        internal
        returns (uint256)
    {
        bytes32 validatorPubkeyHash = validatorFields[BeaconChainProofs.VALIDATOR_PUBKEY_INDEX];

        require(validatorPubkeyHash == BeaconChainProofs.hashValidatorBLSPubkey(validatorPubkey),
            "EigenPod._verifyWithdrawalCredentials: validatorPubkeyHash does not match validatorPubkey");

        ValidatorInfo memory validatorInfo = _validatorPubkeyHashToInfo[validatorPubkeyHash];

        require(validatorInfo.status == VALIDATOR_STATUS.INACTIVE,
            "EigenPod.verifyCorrectWithdrawalCredentials: Validator must be inactive to prove withdrawal credentials");

        require(validatorFields[BeaconChainProofs.VALIDATOR_WITHDRAWAL_CREDENTIALS_INDEX] == bytes32(_podWithdrawalCredentials()),
            "EigenPod.verifyCorrectWithdrawalCredentials: Proof is not for this EigenPod");
        /**
        * Deserialize the balance field from the Validator struct.  Note that this is the "effective" balance of the validator
        * rather than the current balance.  Effective balance is generated via a hystersis function such that an effective 
        * balance, always a multiple of 1 ETH, will only lower to the next multiple of 1 ETH if the current balance is less
        * than 0.25 ETH below their current effective balance.  For example, if the effective balance is 31ETH, it only falls to 
        * 30ETH when the true balance falls below 30.75ETH.  Thus in the worst case, the effective balance is overestimating the
        * actual validator balance by 0.25 ETH.  In EigenLayer, we calculate our own "restaked balance" which is a further pessimistic
        * view of the validator's effective balance.
        */
        uint64 validatorEffectiveBalanceGwei = Endian.fromLittleEndianUint64(validatorFields[BeaconChainProofs.VALIDATOR_BALANCE_INDEX]);

        // verify ETH validator proof
        bytes32 latestBlockRoot = eigenPodManager.getBlockRootAtTimestamp(oracleTimestamp);

        // verify that the provided state root is verified against the oracle-provided latest block header
        BeaconChainProofs.verifyStateRootAgainstLatestBlockRoot({
            latestBlockRoot: latestBlockRoot,
            beaconStateRoot: withdrawalCredentialProof.beaconStateRoot,
            stateRootProof: withdrawalCredentialProof.stateRootProof
        });

        // verify the provided ValidatorFields against the provided state root, now that it has been proven against the latest block header
        BeaconChainProofs.verifyValidatorFields({
            beaconStateRoot: withdrawalCredentialProof.beaconStateRoot,
            validatorFields: validatorFields,
            validatorFieldsProof: withdrawalCredentialProof.validatorFieldsProof,
            validatorIndex: validatorIndex
        });

        // set the status to active
        validatorInfo.status = VALIDATOR_STATUS.ACTIVE;
        validatorInfo.validatorIndex = validatorIndex;
        validatorInfo.mostRecentBalanceUpdateTimestamp = oracleTimestamp;

        // record validator's new restaked balance
        validatorInfo.restakedBalanceGwei = _calculateRestakedBalanceGwei(validatorEffectiveBalanceGwei);

        emit ValidatorRestaked(validatorIndex, validatorPubkeyHash, validatorPubkey);
        emit ValidatorBalanceUpdated(validatorIndex, oracleTimestamp, validatorInfo.restakedBalanceGwei);

        // record validatorInfo update in storage
        _validatorPubkeyHashToInfo[validatorPubkeyHash] = validatorInfo;

        return validatorInfo.restakedBalanceGwei * GWEI_TO_WEI;
    }


    function _verifyAndProcessWithdrawal(
        uint64 oracleTimestamp,
        BeaconChainProofs.WithdrawalProof calldata withdrawalProof, 
        bytes calldata validatorFieldsProof,
        bytes32[] calldata validatorFields,
        bytes32[] calldata withdrawalFields
    )
        internal
        /** 
         * Check that the provided block number being proven against is after the `mostRecentWithdrawalTimestamp`.
         * Without this check, there is an edge case where a user proves a past withdrawal for a validator whose funds they already withdrew,
         * as a way to "withdraw the same funds twice" without providing adequate proof.
         * Note that this check is not made using the oracleTimestamp as in the `verifyWithdrawalCredentials` proof; instead this proof
         * proof is made for the timestamp of the withdrawal, which may be within SLOTS_PER_HISTORICAL_ROOT slots of the oracleTimestamp. 
         * This difference in modifier usage is OK, since it is still not possible to `verifyAndProcessWithdrawal` against a slot that occurred
         * *prior* to the proof provided in the `verifyWithdrawalCredentials` function.
         */
        proofIsForValidTimestamp(Endian.fromLittleEndianUint64(withdrawalProof.timestampRoot))
    {
        uint64 withdrawalHappenedTimestamp = _computeTimestampAtSlot(Endian.fromLittleEndianUint64(withdrawalProof.slotRoot));
        
        bytes32 validatorPubkeyHash = validatorFields[BeaconChainProofs.VALIDATOR_PUBKEY_INDEX];

        /**
         * If the validator status is inactive, then withdrawal credentials were never verified for the validator,
         * and thus we cannot know that the validator is related to this EigenPod at all!
         */
        ValidatorInfo memory validatorInfo = _validatorPubkeyHashToInfo[validatorPubkeyHash];
        require(validatorInfo.status != VALIDATOR_STATUS.INACTIVE,
            "EigenPod._verifyAndProcessWithdrawal: Validator never proven to have withdrawal credentials pointed to this contract");

        
        require(!provenWithdrawal[validatorPubkeyHash][withdrawalHappenedTimestamp],
            "EigenPod._verifyAndProcessWithdrawal: withdrawal has already been proven for this timestamp");

        provenWithdrawal[validatorPubkeyHash][withdrawalHappenedTimestamp] = true;
        
    
        // verify that the provided state root is verified against the oracle-provided latest block header
        BeaconChainProofs.verifyStateRootAgainstLatestBlockRoot({
            latestBlockRoot: eigenPodManager.getBlockRootAtTimestamp(oracleTimestamp),
            beaconStateRoot: withdrawalProof.beaconStateRoot,
            stateRootProof: withdrawalProof.stateRootProof
        });


        // Verifying the withdrawal as well as the slot
        BeaconChainProofs.verifyWithdrawal({
            withdrawalFields: withdrawalFields,
            withdrawalProof: withdrawalProof
        });
        
        {
            uint40 validatorIndex = uint40(Endian.fromLittleEndianUint64(withdrawalFields[BeaconChainProofs.WITHDRAWAL_VALIDATOR_INDEX_INDEX]));

             // Verifying the validator fields, specifically the withdrawable epoch
            BeaconChainProofs.verifyValidatorFields({
                beaconStateRoot: withdrawalProof.beaconStateRoot,
                validatorFields: validatorFields,
                validatorFieldsProof: validatorFieldsProof,
                validatorIndex: validatorIndex
            });

            uint64 withdrawalAmountGwei = Endian.fromLittleEndianUint64(withdrawalFields[BeaconChainProofs.WITHDRAWAL_VALIDATOR_AMOUNT_INDEX]);
            uint64 slot = Endian.fromLittleEndianUint64(withdrawalProof.slotRoot);

            /**
            * if the validator's withdrawable epoch is less than or equal to the slot's epoch, then the validator has fully withdrawn because
            * a full withdrawal is only processable after the withdrawable epoch has passed.
            */
            // reference: uint64 withdrawableEpoch = Endian.fromLittleEndianUint64(validatorFields[BeaconChainProofs.VALIDATOR_WITHDRAWABLE_EPOCH_INDEX]);
            if (Endian.fromLittleEndianUint64(validatorFields[BeaconChainProofs.VALIDATOR_WITHDRAWABLE_EPOCH_INDEX]) <= slot/BeaconChainProofs.SLOTS_PER_EPOCH) {
                _processFullWithdrawal(validatorIndex, validatorPubkeyHash, withdrawalHappenedTimestamp, podOwner, withdrawalAmountGwei, validatorInfo);
            } else {
                _processPartialWithdrawal(validatorIndex, withdrawalHappenedTimestamp, podOwner, withdrawalAmountGwei);
            }
        }
    }

    function _processFullWithdrawal(
        uint40 validatorIndex,
        bytes32 validatorPubkeyHash,
        uint64 withdrawalHappenedTimestamp,
        address recipient,
        uint64 withdrawalAmountGwei,
        ValidatorInfo memory validatorInfo
    ) internal {
        uint256 amountToSend;
        uint256 withdrawalAmountWei;

        uint256 currentValidatorRestakedBalanceWei = validatorInfo.restakedBalanceGwei * GWEI_TO_WEI;
        
        /**
        * If the validator is already withdrawn and additional deposits are made, they will be automatically withdrawn
        * in the beacon chain as a full withdrawal.  Thus such a validator can prove another full withdrawal, and 
        * withdraw that ETH via the queuedWithdrawal flow in the strategy manager. 
        */
        if (validatorInfo.status == VALIDATOR_STATUS.ACTIVE) {
            // if the withdrawal amount is greater than the MAX_VALIDATOR_BALANCE_GWEI (i.e. the max amount restaked on EigenLayer, per ETH validator)
            uint64 maxRestakedBalanceGwei = _calculateRestakedBalanceGwei(MAX_VALIDATOR_BALANCE_GWEI);
            if (withdrawalAmountGwei > maxRestakedBalanceGwei) {
                // then the excess is immediately withdrawable
                amountToSend = uint256(withdrawalAmountGwei - maxRestakedBalanceGwei) * uint256(GWEI_TO_WEI);
                // and the extra execution layer ETH in the contract is MAX_VALIDATOR_BALANCE_GWEI, which must be withdrawn through EigenLayer's normal withdrawal process
                withdrawableRestakedExecutionLayerGwei += maxRestakedBalanceGwei;
                withdrawalAmountWei = maxRestakedBalanceGwei * GWEI_TO_WEI;
                
            } else {

                // otherwise, just use the full withdrawal amount to continue to "back" the podOwner's remaining shares in EigenLayer (i.e. none is instantly withdrawable)
                withdrawalAmountGwei = _calculateRestakedBalanceGwei(withdrawalAmountGwei);
                withdrawableRestakedExecutionLayerGwei += withdrawalAmountGwei;
                withdrawalAmountWei = withdrawalAmountGwei * GWEI_TO_WEI;

            }
            // if the amount being withdrawn is not equal to the current accounted for validator balance, an update must be made
            if (currentValidatorRestakedBalanceWei != withdrawalAmountWei) {
                int256 sharesDelta = _calculateSharesDelta({newAmountWei: withdrawalAmountWei, currentAmountWei: currentValidatorRestakedBalanceWei});
                //update podOwner's shares in the strategy manager
                eigenPodManager.recordBeaconChainETHBalanceUpdate(podOwner, sharesDelta);
            }

        }  else {
            revert("EigenPod.verifyBeaconChainFullWithdrawal: VALIDATOR_STATUS is invalid VALIDATOR_STATUS");
        }

        // now that the validator has been proven to be withdrawn, we can set their restaked balance to 0
        validatorInfo.restakedBalanceGwei = 0;
        validatorInfo.status = VALIDATOR_STATUS.WITHDRAWN;
        validatorInfo.mostRecentBalanceUpdateTimestamp = withdrawalHappenedTimestamp;

        _validatorPubkeyHashToInfo[validatorPubkeyHash] = validatorInfo;

        emit FullWithdrawalRedeemed(validatorIndex, withdrawalHappenedTimestamp, recipient, withdrawalAmountGwei);

        // send ETH to the `recipient` via the DelayedWithdrawalRouter, if applicable
        if (amountToSend != 0) {
            _sendETH_AsDelayedWithdrawal(recipient, amountToSend);
        }
    }

    function _processPartialWithdrawal(
        uint40 validatorIndex,
        uint64 withdrawalHappenedTimestamp,
        address recipient,
        uint64 partialWithdrawalAmountGwei
    ) internal {
        emit PartialWithdrawalRedeemed(validatorIndex, withdrawalHappenedTimestamp, recipient, partialWithdrawalAmountGwei);

        // send the ETH to the `recipient` via the DelayedWithdrawalRouter
        _sendETH_AsDelayedWithdrawal(recipient, uint256(partialWithdrawalAmountGwei) * uint256(GWEI_TO_WEI));
    }

    function _processWithdrawalBeforeRestaking(address _podOwner) internal {
        mostRecentWithdrawalTimestamp = uint32(block.timestamp);
        _sendETH_AsDelayedWithdrawal(_podOwner, address(this).balance);
    }

    function _sendETH(address recipient, uint256 amountWei) internal {
        Address.sendValue(payable(recipient), amountWei);
    }

    function _sendETH_AsDelayedWithdrawal(address recipient, uint256 amountWei) internal {
        delayedWithdrawalRouter.createDelayedWithdrawal{value: amountWei}(podOwner, recipient);
    }

    function _calculateRestakedBalanceGwei(uint64 amountGwei) internal view returns (uint64){
        if (amountGwei <= RESTAKED_BALANCE_OFFSET_GWEI) {
            return 0;
        }
        /**
        * calculates the "floor" of amountGwei - RESTAKED_BALANCE_OFFSET_GWEI.  By using integer division 
        * (dividing by GWEI_TO_WEI = 1e9) and then multiplying by 1e9, we effectively "round down" amountGwei to 
        * the nearest ETH, effectively calculating the floor of amountGwei.
        */
        // slither-disable-next-line divide-before-multiply
        uint64 effectiveBalanceGwei = uint64((amountGwei - RESTAKED_BALANCE_OFFSET_GWEI) / GWEI_TO_WEI * GWEI_TO_WEI);
        return uint64(MathUpgradeable.min(MAX_VALIDATOR_BALANCE_GWEI, effectiveBalanceGwei));
    }

    function _podWithdrawalCredentials() internal view returns(bytes memory) {
        return abi.encodePacked(bytes1(uint8(1)), bytes11(0), address(this));
    }

    function _calculateSharesDelta(uint256 newAmountWei, uint256 currentAmountWei) internal pure returns(int256){
        return (int256(newAmountWei) - int256(currentAmountWei));
    }

    // reference: https://github.com/ethereum/consensus-specs/blob/ce240ca795e257fc83059c4adfd591328c7a7f21/specs/bellatrix/beacon-chain.md#compute_timestamp_at_slot
    function _computeTimestampAtSlot(uint64 slot) internal view returns (uint64) {
        return uint64(GENESIS_TIME + slot * SECONDS_PER_SLOT);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[45] private __gap;
}