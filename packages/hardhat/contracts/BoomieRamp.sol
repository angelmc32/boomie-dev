//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Useful for debugging. Remove when deploying to a live network.
import "hardhat/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Bytes32ArrayUtils } from "./external/Bytes32ArrayUtils.sol";
import { Uint256ArrayUtils } from "./external/Uint256ArrayUtils.sol";

/**
 * A smart contract that allows changing a state variable of the contract and tracking the changes
 * It also allows the owner to withdraw the Ether in the contract
 * @author BuidlGuidl
 */
contract BoomieRamp is Ownable {
	using Bytes32ArrayUtils for bytes32[];
	using Uint256ArrayUtils for uint256[];

	event AccountRegistered(
		address indexed accountOwner,
		bytes32 indexed venmoIdHash
	);
	event DepositReceived(
		uint256 indexed depositId,
		address indexed sellerAccount,
		uint256 amount,
		uint256 conversionRate
	);
	event IntentSignaled(
		bytes32 indexed intentHash,
		uint256 indexed depositId,
		address indexed buyerAccount,
		address to,
		uint256 amount,
		uint256 timestamp
	);

	event IntentPruned(bytes32 indexed intentHash, uint256 indexed depositId);
	// Do we want to emit the buyerAccount
	event IntentFulfilled(
		bytes32 indexed intentHash,
		uint256 indexed depositId,
		address indexed buyerAccount,
		address to,
		uint256 amount,
		uint256 feeAmount
	);
	// Do we want to emit the depositor or the venmoId
	event DepositWithdrawn(
		uint256 indexed depositId,
		address indexed sellerAccount,
		uint256 amount
	);

	event DepositClosed(uint256 depositId, address sellerAccount);
	event UserAddedToDenylist(bytes32 listOwner, bytes32 deniedUser);
	event UserRemovedFromDenylist(bytes32 listOwner, bytes32 approvedUser);
	event MinDepositAmountSet(uint256 minDepositAmount);
	event MaxOnRampAmountSet(uint256 maxOnRampAmount);
	event IntentExpirationPeriodSet(uint256 intentExpirationPeriod);
	event OnRampCooldownPeriodSet(uint256 onRampCooldownPeriod);
	event SustainabilityFeeUpdated(uint256 fee);
	event SustainabilityFeeRecipientUpdated(address feeRecipient);

	/* ============ Structs ============ */

	// Each Account is tied to a GlobalAccount via its associated venmoIdHash. Each account is represented by an Ethereum address
	// and is allowed to have at most 5 deposits associated with it.
	struct AccountInfo {
		bytes32 venmoIdHash; // current is hash of msg.sender, prev - Poseidon hash of account's venmoId
		uint256[] deposits; // Array of open account deposits
	}

	struct Deposit {
		address depositor;
		uint256 depositAmount; // Amount of GHO deposited
		uint256 remainingDeposits; // Amount of remaining deposited liquidity
		uint256 outstandingIntentAmount; // Amount of outstanding intents (may include expired intents)
		uint256 conversionRate; // Conversion required by off-ramper between GHO/XOC
		bytes32[] intentHashes; // Array of hashes of all open intents (may include some expired if not pruned)
	}

	struct DepositWithAvailableLiquidity {
		uint256 depositId; // ID of the deposit
		bytes32 depositorIdHash; // Depositor's venmoIdHash
		Deposit deposit; // Deposit struct
		uint256 availableLiquidity; // Amount of liquidity available to signal intents (net of expired intents)
	}

	struct Intent {
		address buyerAccount; // On-ramper's address
		address to; // Address to forward funds to (can be same as buyerAccount)
		uint256 deposit; // ID of the deposit the intent is signaling on
		uint256 amount; // Amount of GHO the on-ramper signals intent for on-chain
		uint256 intentTimestamp; // Timestamp of when the intent was signaled
	}

	struct IntentWithOnRamperId {
		bytes32 intentHash; // Intent hash
		Intent intent; // Intent struct
		bytes32 onRamperIdHash; // Poseidon hash of the on-ramper's venmoId
	}

	struct DenyList {
		bytes32[] deniedUsers; // Array of venmoIdHashes that are denied from taking depositors liquidity
		mapping(bytes32 => bool) isDenied; // Mapping of venmoIdHash to boolean indicating if the user is denied
	}

	// A Global Account is defined as an account represented by one venmoIdHash. This is used to enforce limitations on actions across
	// all Ethereum addresses that are associated with that venmoId. In this case we use it to enforce a cooldown period between on ramps,
	// restrict each venmo account to one outstanding intent at a time, and to enforce deny lists.
	struct GlobalAccountInfo {
		bytes32 currentIntentHash; // Hash of the current open intent (if exists)
		uint256 lastOnrampTimestamp; // Timestamp of the last on-ramp transaction used to check if cooldown period elapsed
		DenyList denyList; // Deny list of the account
	}

	/* ============ Modifiers ============ */
	// TODO - change function to check for whitelisted users
	modifier onlyRegisteredUser() {
		require(
			getAccountVenmoIdHash(msg.sender) != bytes32(0),
			"Caller must be registered user"
		);
		_;
	}

	/* ============ Constants ============ */
	uint256 internal constant PRECISE_UNIT = 1e18;
	uint256 internal constant MAX_DEPOSITS = 5; // An account can only have max 5 different deposit parameterizations to prevent locking funds
	uint256 constant MAX_SUSTAINABILITY_FEE = 5e16; // 5% max sustainability fee

	/* ============ State Variables ============ */
	IERC20 public immutable gho; // GHO token contract

	bool public isInitialized; // Indicates if contract has been initialized

	// TODO - update GlobalAccountInfo to just an address?
	// Follow-up - we can still use the address as the bytes32 variable and link the GlobalAccountInfo to it
	mapping(bytes32 => GlobalAccountInfo) internal globalAccount; // Mapping of venmoIdHash to information used to enforce actions across Ethereum accounts
	mapping(address => AccountInfo) internal accounts; // Mapping of Ethereum accounts to their account information (venmoIdHash and deposits)
	mapping(uint256 => Deposit) public deposits; // Mapping of depositIds to deposit structs
	mapping(bytes32 => Intent) public intents; // Mapping of intentHashes to intent structs

	uint256 public minDepositAmount; // Minimum amount of GHO that can be deposited
	uint256 public maxOnRampAmount; // Maximum amount of GHO that can be on-ramped in a single transaction
	uint256 public onRampCooldownPeriod; // Time period that must elapse between completing an on-ramp and signaling a new intent
	uint256 public intentExpirationPeriod; // Time period after which an intent can be pruned from the system
	uint256 public sustainabilityFee; // Fee charged to on-rampers in preciseUnits (1e16 = 1%)
	address public sustainabilityFeeRecipient; // Address that receives the sustainability fee

	uint256 public depositCounter; // Counter for depositIds

	/* ============ Constructor ============ */
	constructor(
		address _owner,
		IERC20 _gho,
		uint256 _minDepositAmount,
		uint256 _maxOnRampAmount,
		uint256 _intentExpirationPeriod,
		uint256 _onRampCooldownPeriod,
		uint256 _sustainabilityFee,
		address _sustainabilityFeeRecipient
	) Ownable() {
		gho = _gho;
		minDepositAmount = _minDepositAmount;
		maxOnRampAmount = _maxOnRampAmount;
		intentExpirationPeriod = _intentExpirationPeriod;
		onRampCooldownPeriod = _onRampCooldownPeriod;
		sustainabilityFee = _sustainabilityFee;
		sustainabilityFeeRecipient = _sustainabilityFeeRecipient;

		transferOwnership(_owner);
	}

	/* ============ External Functions ============ */

	/**
	 * @notice Initialize Ramp with the addresses of the Processors
	 */
	function initialize() external onlyOwner {
		require(!isInitialized, "Already initialized");

		isInitialized = true;
	}

	// TODO - switch registration to register additional ethereum accounts under one account
	/**
	 * @notice Registers a new account
	 */
	function register() external {
		require(
			getAccountVenmoIdHash(msg.sender) == bytes32(0),
			"Account already associated with venmoId"
		);
		address senderAddress = msg.sender;
		bytes32 venmoIdHash = bytes32(uint256(uint160(senderAddress)));

		accounts[msg.sender].venmoIdHash = venmoIdHash;

		emit AccountRegistered(msg.sender, venmoIdHash);
	}

	/**
	 * @notice Generates a deposit entry for off-rampers that can then be fulfilled by an on-ramper. This function will not add to
	 * previous deposits. Every deposit has it's own unique identifier. User must approve the contract to transfer the deposit amount
	 * of GHO.
	 *
	 * @param _depositAmount    The amount of GHO to off-ramp
	 * @param _receiveAmount    The amount of XOC to receive
	 */
	function offRamp(
		uint256 _depositAmount,
		uint256 _receiveAmount
	) external onlyRegisteredUser {
		require(
			accounts[msg.sender].deposits.length < MAX_DEPOSITS,
			"Maximum deposit amount reached"
		);
		require(
			_depositAmount >= minDepositAmount,
			"Deposit amount must be greater than min deposit amount"
		);
		require(_receiveAmount > 0, "Receive amount must be greater than 0");

		uint256 conversionRate = (_depositAmount * PRECISE_UNIT) /
			_receiveAmount;
		uint256 depositId = depositCounter++;

		accounts[msg.sender].deposits.push(depositId);

		deposits[depositId] = Deposit({
			depositor: msg.sender,
			depositAmount: _depositAmount,
			remainingDeposits: _depositAmount,
			outstandingIntentAmount: 0,
			conversionRate: conversionRate,
			intentHashes: new bytes32[](0)
		});

		gho.transferFrom(msg.sender, address(this), _depositAmount);

		emit DepositReceived(
			depositId,
			msg.sender,
			_depositAmount,
			conversionRate
		);
	}

	// TODO - replace getAccountVenmoIdHash for getGlobalAccount, which should return the user address
	// TODO - replace venmoIdHash with the buyerAccount (just use msg.sender)
	// TODO - replace depositorVenmoHasId with the sellerAccount
	// TODO - replace _calculateIntentHash param (venmoIdHash) with buyerAccount
	/**
	 * @notice Signals intent to pay the depositor defined in the _depositId the _amount * deposit conversionRate off-chain
	 * in order to unlock _amount of funds on-chain. Each user can only have one outstanding intent at a time regardless of
	 * address (tracked using globalAccount). Caller must not be on the depositor's deny list. If there are prunable intents then
	 * they will be deleted from the deposit to be able to maintain state hygiene.
	 *
	 * @param _depositId    The ID of the deposit the on-ramper intends to use for
	 * @param _amount       The amount of GHO the user wants to on-ramp
	 * @param _to           Address to forward funds to (can be same as buyerAccount)
	 */
	function signalIntent(
		uint256 _depositId,
		uint256 _amount,
		address _to
	) external onlyRegisteredUser {
		bytes32 venmoIdHash = getAccountVenmoIdHash(msg.sender);
		Deposit storage deposit = deposits[_depositId];
		bytes32 depositorVenmoIdHash = getAccountVenmoIdHash(deposit.depositor);

		// Caller validity checks
		require(
			!globalAccount[depositorVenmoIdHash].denyList.isDenied[venmoIdHash],
			"Onramper on depositor's denylist"
		);
		require(
			globalAccount[venmoIdHash].lastOnrampTimestamp +
				onRampCooldownPeriod <=
				block.timestamp,
			"On ramp cool down period not elapsed"
		);
		require(
			globalAccount[venmoIdHash].currentIntentHash == bytes32(0),
			"Intent still outstanding"
		);
		require(
			depositorVenmoIdHash != venmoIdHash,
			"Sender cannot be the depositor"
		);

		// Intent information checks
		require(deposit.depositor != address(0), "Deposit does not exist");
		require(_amount > 0, "Signaled amount must be greater than 0");
		require(
			_amount <= maxOnRampAmount,
			"Signaled amount must be less than max on-ramp amount"
		);
		require(_to != address(0), "Cannot send to zero address");

		bytes32 intentHash = _calculateIntentHash(_depositId);

		if (deposit.remainingDeposits < _amount) {
			(
				bytes32[] memory prunableIntents,
				uint256 reclaimableAmount
			) = _getPrunableIntents(_depositId);

			require(
				deposit.remainingDeposits + reclaimableAmount >= _amount,
				"Not enough liquidity"
			);

			_pruneIntents(deposit, prunableIntents);
			deposit.remainingDeposits += reclaimableAmount;
			deposit.outstandingIntentAmount -= reclaimableAmount;
		}

		intents[intentHash] = Intent({
			buyerAccount: msg.sender,
			to: _to,
			deposit: _depositId,
			amount: _amount,
			intentTimestamp: block.timestamp
		});

		globalAccount[venmoIdHash].currentIntentHash = intentHash;

		deposit.remainingDeposits -= _amount;
		deposit.outstandingIntentAmount += _amount;
		deposit.intentHashes.push(intentHash);

		address venmoIdHashAsAddress = address(uint160(uint256(venmoIdHash)));

		emit IntentSignaled(
			intentHash,
			_depositId,
			venmoIdHashAsAddress,
			_to,
			_amount,
			block.timestamp
		);
	}

	// TODO - replace getAccountVenmoIdHash with plain address comparison?
	/**
	 * @notice Only callable by the originator of the intent. Cancels an outstanding intent thus allowing user to signal a new
	 * intent. Deposit state is updated to reflect the cancelled intent.
	 *
	 * @param _intentHash    Hash of intent being cancelled
	 */
	function cancelIntent(bytes32 _intentHash) external {
		Intent memory intent = intents[_intentHash];

		require(intent.intentTimestamp != 0, "Intent does not exist");
		require(
			getAccountVenmoIdHash(intent.buyerAccount) ==
				getAccountVenmoIdHash(msg.sender),
			"Sender must be the on-ramper"
		);

		Deposit storage deposit = deposits[intent.deposit];

		_pruneIntent(deposit, _intentHash);

		deposit.remainingDeposits += intent.amount;
		deposit.outstandingIntentAmount -= intent.amount;
	}

	// TODO - replace verification with plain token transfer?
	/**
	 * @notice Anyone can submit an on-ramp transaction, even if caller isn't on-ramper. Upon submission the proof is validated,
	 * intent is removed, and deposit state is updated. GHO is transferred to the on-ramper.
	 *
	 * @param _intentHash       intentHash
	 */
	function onRamp(bytes32 _intentHash) external {
		Intent memory intent = intents[_intentHash];
		Deposit storage deposit = deposits[intent.deposit];

		_pruneIntent(deposit, _intentHash);

		deposit.outstandingIntentAmount -= intent.amount;
		globalAccount[getAccountVenmoIdHash(intent.buyerAccount)]
			.lastOnrampTimestamp = block.timestamp;
		_closeDepositIfNecessary(intent.deposit, deposit);

		_transferFunds(_intentHash, intent);
	}

	/**
	 * @notice Allows off-ramper to release funds to the on-ramper in case of a failed on-ramp or because of some other arrangement
	 * between the two parties. Upon submission we check to make sure the msg.sender is the depositor, the  intent is removed, and
	 * deposit state is updated. GHO is transferred to the on-ramper.
	 *
	 * @param _intentHash        Hash of intent to resolve by releasing the funds
	 */
	function releaseFundsToOnramper(bytes32 _intentHash) external {
		Intent memory intent = intents[_intentHash];
		Deposit storage deposit = deposits[intent.deposit];

		require(intent.buyerAccount != address(0), "Intent does not exist");
		require(
			deposit.depositor == msg.sender,
			"Caller must be the depositor"
		);

		_pruneIntent(deposit, _intentHash);

		deposit.outstandingIntentAmount -= intent.amount;
		globalAccount[getAccountVenmoIdHash(intent.buyerAccount)]
			.lastOnrampTimestamp = block.timestamp;
		_closeDepositIfNecessary(intent.deposit, deposit);

		_transferFunds(_intentHash, intent);
	}

	/**
	 * @notice Caller must be the depositor for each depositId in the array, if not whole function fails. Depositor is returned all
	 * remaining deposits and any outstanding intents that are expired. If an intent is not expired then those funds will not be
	 * returned. Deposit will be deleted as long as there are no more outstanding intents.
	 *
	 * @param _depositIds   Array of depositIds the depositor is attempting to withdraw
	 */
	function withdrawDeposit(uint256[] memory _depositIds) external {
		uint256 returnAmount;

		for (uint256 i = 0; i < _depositIds.length; ++i) {
			uint256 depositId = _depositIds[i];
			Deposit storage deposit = deposits[depositId];

			require(
				deposit.depositor == msg.sender,
				"Sender must be the depositor"
			);

			(
				bytes32[] memory prunableIntents,
				uint256 reclaimableAmount
			) = _getPrunableIntents(depositId);

			_pruneIntents(deposit, prunableIntents);

			returnAmount += deposit.remainingDeposits + reclaimableAmount;

			deposit.outstandingIntentAmount -= reclaimableAmount;

			emit DepositWithdrawn(
				depositId,
				deposit.depositor,
				deposit.remainingDeposits + reclaimableAmount
			);

			delete deposit.remainingDeposits;
			_closeDepositIfNecessary(depositId, deposit);
		}

		gho.transfer(msg.sender, returnAmount);
	}

	/**
	 * @notice Adds a venmoId to a depositor's deny list. If an address associated with the banned venmoId attempts to
	 * signal an intent on the user's deposit they will be denied.
	 *
	 * @param _deniedUser   Poseidon hash of the venmoId being banned
	 */
	function addAccountToDenylist(
		bytes32 _deniedUser
	) external onlyRegisteredUser {
		bytes32 denyingUser = getAccountVenmoIdHash(msg.sender);

		require(
			!globalAccount[denyingUser].denyList.isDenied[_deniedUser],
			"User already on denylist"
		);

		globalAccount[denyingUser].denyList.isDenied[_deniedUser] = true;
		globalAccount[denyingUser].denyList.deniedUsers.push(_deniedUser);

		emit UserAddedToDenylist(denyingUser, _deniedUser);
	}

	// TODO - replace getAccountVenmoIdHash
	/**
	 * @notice Removes a venmoId from a depositor's deny list.
	 *
	 * @param _approvedUser   Poseidon hash of the venmoId being approved
	 */
	function removeAccountFromDenylist(
		bytes32 _approvedUser
	) external onlyRegisteredUser {
		bytes32 approvingUser = getAccountVenmoIdHash(msg.sender);

		require(
			globalAccount[approvingUser].denyList.isDenied[_approvedUser],
			"User not on denylist"
		);

		globalAccount[approvingUser].denyList.isDenied[_approvedUser] = false;
		globalAccount[approvingUser].denyList.deniedUsers.removeStorage(
			_approvedUser
		);

		emit UserRemovedFromDenylist(approvingUser, _approvedUser);
	}

	/* ============ Governance Functions ============ */

	/**
	 * @notice GOVERNANCE ONLY: Updates the minimum deposit amount a user can specify for off-ramping.
	 *
	 * @param _minDepositAmount   The new minimum deposit amount
	 */
	function setMinDepositAmount(uint256 _minDepositAmount) external onlyOwner {
		require(_minDepositAmount != 0, "Minimum deposit cannot be zero");

		minDepositAmount = _minDepositAmount;
		emit MinDepositAmountSet(_minDepositAmount);
	}

	/**
	 * @notice GOVERNANCE ONLY: Updates the sustainability fee. This fee is charged to on-rampers upon a successful on-ramp.
	 *
	 * @param _fee   The new sustainability fee in precise units (10**18, ie 10% = 1e17)
	 */
	function setSustainabilityFee(uint256 _fee) external onlyOwner {
		require(
			_fee <= MAX_SUSTAINABILITY_FEE,
			"Fee cannot be greater than max fee"
		);

		sustainabilityFee = _fee;
		emit SustainabilityFeeUpdated(_fee);
	}

	/**
	 * @notice GOVERNANCE ONLY: Updates the recepient of sustainability fees.
	 *
	 * @param _feeRecipient   The new fee recipient address
	 */
	function setSustainabilityFeeRecipient(
		address _feeRecipient
	) external onlyOwner {
		require(
			_feeRecipient != address(0),
			"Fee recipient cannot be zero address"
		);

		sustainabilityFeeRecipient = _feeRecipient;
		emit SustainabilityFeeRecipientUpdated(_feeRecipient);
	}

	/**
	 * @notice GOVERNANCE ONLY: Updates the max amount allowed to be on-ramped in each transaction. To on-ramp more than
	 * this amount a user must make multiple transactions.
	 *
	 * @param _maxOnRampAmount   The new max on ramp amount
	 */
	function setMaxOnRampAmount(uint256 _maxOnRampAmount) external onlyOwner {
		require(_maxOnRampAmount != 0, "Max on ramp amount cannot be zero");

		maxOnRampAmount = _maxOnRampAmount;
		emit MaxOnRampAmountSet(_maxOnRampAmount);
	}

	/**
	 * @notice GOVERNANCE ONLY: Updates the on-ramp cooldown period, once an on-ramp transaction is completed the user must wait this
	 * amount of time before they can signalIntent to on-ramp again.
	 *
	 * @param _onRampCooldownPeriod   New on-ramp cooldown period
	 */
	function setOnRampCooldownPeriod(
		uint256 _onRampCooldownPeriod
	) external onlyOwner {
		onRampCooldownPeriod = _onRampCooldownPeriod;
		emit OnRampCooldownPeriodSet(_onRampCooldownPeriod);
	}

	/**
	 * @notice GOVERNANCE ONLY: Updates the intent expiration period, after this period elapses an intent can be pruned to prevent
	 * locking up a depositor's funds.
	 *
	 * @param _intentExpirationPeriod   New intent expiration period
	 */
	function setIntentExpirationPeriod(
		uint256 _intentExpirationPeriod
	) external onlyOwner {
		require(
			_intentExpirationPeriod != 0,
			"Max intent expiration period cannot be zero"
		);

		intentExpirationPeriod = _intentExpirationPeriod;
		emit IntentExpirationPeriodSet(_intentExpirationPeriod);
	}

	/* ============ External View Functions ============ */

	function getDeposit(
		uint256 _depositId
	) external view returns (Deposit memory) {
		return deposits[_depositId];
	}

	function getAccountInfo(
		address _account
	) external view returns (AccountInfo memory) {
		return
			AccountInfo({
				venmoIdHash: getAccountVenmoIdHash(_account),
				deposits: accounts[_account].deposits
			});
	}

	function getAccountVenmoIdHash(
		address _account
	) public view returns (bytes32) {
		return accounts[_account].venmoIdHash;
	}

	function getVenmoIdCurrentIntentHash(
		address _account
	) external view returns (bytes32) {
		return globalAccount[getAccountVenmoIdHash(_account)].currentIntentHash;
	}

	function getLastOnRampTimestamp(
		address _account
	) external view returns (uint256) {
		return
			globalAccount[getAccountVenmoIdHash(_account)].lastOnrampTimestamp;
	}

	function getDeniedUsers(
		address _account
	) external view returns (bytes32[] memory) {
		return
			globalAccount[getAccountVenmoIdHash(_account)].denyList.deniedUsers;
	}

	function isDeniedUser(
		address _account,
		bytes32 _deniedUser
	) external view returns (bool) {
		return
			globalAccount[getAccountVenmoIdHash(_account)].denyList.isDenied[
				_deniedUser
			];
	}

	function getIntentsWithOnRamperId(
		bytes32[] calldata _intentHashes
	) external view returns (IntentWithOnRamperId[] memory) {
		IntentWithOnRamperId[]
			memory intentsWithOnRamperId = new IntentWithOnRamperId[](
				_intentHashes.length
			);

		for (uint256 i = 0; i < _intentHashes.length; ++i) {
			bytes32 intentHash = _intentHashes[i];
			Intent memory intent = intents[intentHash];
			intentsWithOnRamperId[i] = IntentWithOnRamperId({
				intentHash: _intentHashes[i],
				intent: intent,
				onRamperIdHash: getAccountVenmoIdHash(intent.buyerAccount)
			});
		}

		return intentsWithOnRamperId;
	}

	function getAccountDeposits(
		address _account
	)
		external
		view
		returns (DepositWithAvailableLiquidity[] memory accountDeposits)
	{
		uint256[] memory accountDepositIds = accounts[_account].deposits;
		accountDeposits = new DepositWithAvailableLiquidity[](
			accountDepositIds.length
		);

		for (uint256 i = 0; i < accountDepositIds.length; ++i) {
			uint256 depositId = accountDepositIds[i];
			Deposit memory deposit = deposits[depositId];
			(, uint256 reclaimableAmount) = _getPrunableIntents(depositId);

			accountDeposits[i] = DepositWithAvailableLiquidity({
				depositId: depositId,
				depositorIdHash: getAccountVenmoIdHash(deposit.depositor),
				deposit: deposit,
				availableLiquidity: deposit.remainingDeposits +
					reclaimableAmount
			});
		}
	}

	function getDepositFromIds(
		uint256[] memory _depositIds
	)
		external
		view
		returns (DepositWithAvailableLiquidity[] memory depositArray)
	{
		depositArray = new DepositWithAvailableLiquidity[](_depositIds.length);

		for (uint256 i = 0; i < _depositIds.length; ++i) {
			uint256 depositId = _depositIds[i];
			Deposit memory deposit = deposits[depositId];
			(, uint256 reclaimableAmount) = _getPrunableIntents(depositId);

			depositArray[i] = DepositWithAvailableLiquidity({
				depositId: depositId,
				depositorIdHash: getAccountVenmoIdHash(deposit.depositor),
				deposit: deposit,
				availableLiquidity: deposit.remainingDeposits +
					reclaimableAmount
			});
		}

		return depositArray;
	}

	/* ============ Internal Functions ============ */

	// Modified to generate a simple hash instead of zk stuff
	/**
	 * @notice Calculates the intentHash of new intent
	 */
	function _calculateIntentHash(
		uint256 _depositId
	) internal view virtual returns (bytes32) {
		bytes32 intentHash = keccak256(
			abi.encodePacked(msg.sender, _depositId)
		);

		return intentHash;
	}

	/**
	 * @notice Cycles through all intents currently open on a deposit and sees if any have expired. If they have expired
	 * the outstanding amounts are summed and returned alongside the intentHashes
	 */
	function _getPrunableIntents(
		uint256 _depositId
	)
		internal
		view
		returns (bytes32[] memory prunableIntents, uint256 reclaimedAmount)
	{
		bytes32[] memory intentHashes = deposits[_depositId].intentHashes;
		prunableIntents = new bytes32[](intentHashes.length);

		for (uint256 i = 0; i < intentHashes.length; ++i) {
			Intent memory intent = intents[intentHashes[i]];
			if (
				intent.intentTimestamp + intentExpirationPeriod <
				block.timestamp
			) {
				prunableIntents[i] = intentHashes[i];
				reclaimedAmount += intent.amount;
			}
		}
	}

	function _pruneIntents(
		Deposit storage _deposit,
		bytes32[] memory _intents
	) internal {
		for (uint256 i = 0; i < _intents.length; ++i) {
			if (_intents[i] != bytes32(0)) {
				_pruneIntent(_deposit, _intents[i]);
			}
		}
	}

	/**
	 * @notice Pruning an intent involves deleting its state from the intents mapping, zeroing out the intendee's currentIntentHash in
	 * their global account mapping, and deleting the intentHash from the deposit's intentHashes array.
	 */
	function _pruneIntent(
		Deposit storage _deposit,
		bytes32 _intentHash
	) internal {
		Intent memory intent = intents[_intentHash];

		delete globalAccount[getAccountVenmoIdHash(intent.buyerAccount)]
			.currentIntentHash;
		delete intents[_intentHash];
		_deposit.intentHashes.removeStorage(_intentHash);

		emit IntentPruned(_intentHash, intent.deposit);
	}

	/**
	 * @notice Removes a deposit if no outstanding intents AND no remaining deposits. Deleting a deposit deletes it from the
	 * deposits mapping and removes tracking it in the user's accounts mapping.
	 */
	function _closeDepositIfNecessary(
		uint256 _depositId,
		Deposit storage _deposit
	) internal {
		uint256 openDepositAmount = _deposit.outstandingIntentAmount +
			_deposit.remainingDeposits;
		if (openDepositAmount == 0) {
			accounts[_deposit.depositor].deposits.removeStorage(_depositId);
			emit DepositClosed(_depositId, _deposit.depositor);
			delete deposits[_depositId];
		}
	}

	/**
	 * @notice Checks if sustainability fee has been defined, if so sends fee to the fee recipient and intent amount minus fee
	 * to the on-ramper. If sustainability fee is undefined then full intent amount is transferred to on-ramper.
	 */
	function _transferFunds(
		bytes32 _intentHash,
		Intent memory _intent
	) internal {
		uint256 fee;
		if (sustainabilityFee != 0) {
			fee = (_intent.amount * sustainabilityFee) / PRECISE_UNIT;
			gho.transfer(sustainabilityFeeRecipient, fee);
		}

		uint256 onRampAmount = _intent.amount - fee;
		gho.transfer(_intent.to, onRampAmount);

		emit IntentFulfilled(
			_intentHash,
			_intent.deposit,
			_intent.buyerAccount,
			_intent.to,
			onRampAmount,
			fee
		);
	}

	/**
	 * Function that allows the contract to receive ETH
	 */
	receive() external payable {}
}
