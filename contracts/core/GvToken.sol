/// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.11;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IGvToken.sol";
import "../interfaces/IBribePot.sol";
import "../interfaces/IRcaController.sol";
import "../library/MerkleProof.sol";
import "./Delegable.sol";

// solhint-disable not-rely-on-time
// solhint-disable reason-string
// solhint-disable max-states-count
// solhint-disable no-inline-assembly

contract GvToken is Delegable {
    using SafeERC20 for IERC20Permit;

    /* ========== STRUCTS ========== */
    struct MetaData {
        string name;
        string symbol;
        uint256 decimals;
    }
    struct Deposit {
        uint128 amount;
        uint128 start;
    }
    struct PermitArgs {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
    struct WithdrawRequest {
        uint128 amount;
        uint128 endTime;
    }
    struct SupplyPointer {
        uint128 amount;
        uint128 storedAt;
    }
    struct GrowthRate {
        uint128 start;
        uint128 expire;
    }
    struct DelegateDetails {
        address reciever;
        uint256 amount;
    }

    /* ========== CONSTANTS ========== */
    uint64 public constant MAX_PERCENT = 100_000;
    uint32 public constant MAX_GROW = 52 weeks;
    uint32 public constant WEEK = 1 weeks;
    uint256 internal constant MULTIPLIER = 1e18;

    /* ========== STATE ========== */
    IBribePot public immutable pot;
    IERC20Permit public immutable stakingToken;
    IRcaController public immutable rcaController;
    /// @notice Timestamp rounded in weeks for earliest vArmor staker
    uint32 public immutable genesis;
    /// @notice ease governance
    address public gov;
    /// @notice total amount of EASE deposited
    uint256 public totalDeposited;
    /// @notice Time delay for withdrawals which will be set by governance
    uint256 public withdrawalDelay = 14 days;

    /// @notice total supply of gvToken
    uint256 private _totalSupply;
    /// @notice merkle root of vArmor stakers for giving them
    /// extra deposit start time
    bytes32 private _powerRoot;
    MetaData private metadata = MetaData("Growing Vote Ease", "gvEase", 18);
    /// @notice Request by users for withdrawals.
    mapping(address => WithdrawRequest) public withdrawRequests;
    /// @notice amount of gvToken bribed to bribe Pot
    mapping(address => uint256) public bribedAmount;

    /// @notice User deposits of ease tokens
    mapping(address => Deposit[]) private _deposits;
    /// @notice total amount of ease deposited on user behalf
    mapping(address => uint256) private _totalDeposit;
    /// @notice Total percent of balance staked by user to different RCA-vaults
    mapping(address => uint256) private _totalStaked;
    /// @notice Percentage of gvToken stake to each RCA-vault
    /// user => rcaVault => % of gvToken
    mapping(address => mapping(address => uint256)) private _stakes;

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 amount);
    event RedeemRequest(address indexed user, uint256 amount, uint256 endTime);
    event RedeemFinalize(address indexed user, uint256 amount);
    event Stake(
        address indexed user,
        address indexed vault,
        uint256 percentage
    );

    event UnStake(
        address indexed user,
        address indexed vault,
        uint256 percentage
    );

    /* ========== MODIFIERS ========== */
    modifier onlyGov() {
        require(msg.sender == gov, "only gov");
        _;
    }

    /* ========== CONSTRUCTOR ========== */
    /// @notice Construct a new gvToken.
    /// @param _pot Address of a bribe pot.
    /// @param _stakingToken Address of a token to be deposited in exchange
    /// of Growing vote token.
    /// @param _rcaController Address of a RCA controller needed for verifying
    /// active rca vaults.
    /// @param _gov Governance Addresss.
    /// @param _genesis Deposit time of first vArmor holder.
    constructor(
        address _pot,
        address _stakingToken,
        address _rcaController,
        address _gov,
        uint256 _genesis
    ) {
        pot = IBribePot(_pot);
        stakingToken = IERC20Permit(_stakingToken);
        rcaController = IRcaController(_rcaController);
        gov = _gov;
        genesis = uint32((_genesis / WEEK) * WEEK);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function deposit(uint256 amount, PermitArgs memory permit) external {
        _deposit(msg.sender, amount, block.timestamp, permit, false);
    }

    /// @notice Deposit for vArmor holders to give them
    /// extra power when migrating
    /// @param amount Amount of EASE
    /// @param depositStart Extra time start for stakers of Armor Token
    /// as promised by EASE DAO when token migration from ARMOR to EASE
    /// @param proof Merkle proof of the vArmor staker
    /// @param permit v,r,s and deadline for signed approvals (EIP-2612)
    function deposit(
        uint256 amount,
        uint256 depositStart,
        bytes32[] memory proof,
        PermitArgs memory permit
    ) external {
        address user = msg.sender;
        bytes32 leaf = keccak256(abi.encodePacked(user, amount, depositStart));

        require(MerkleProof.verify(proof, _powerRoot, leaf), "invalid proof");
        require(depositStart >= genesis, "depositStart > genesis");

        _deposit(user, amount, depositStart, permit, false);
    }

    /// @notice Request redemption of gvToken back to ease
    /// Has a withdrawal delay which will work in 2 parts(request and finalize)
    /// @param amount The amount of tokens in EASE to withdraw
    /// gvToken from bribe pot if true
    function withdrawRequest(uint256 amount) external {
        address user = msg.sender;
        require(amount <= _totalDeposit[user], "not enough deposit!");
        WithdrawRequest memory currRequest = withdrawRequests[user];

        (uint256 depositBalance, uint256 earnedPower) = _balanceOf(user);

        uint256 gvAmtToWithdraw = _gvTokenValue(
            amount,
            depositBalance,
            earnedPower
        );
        uint256 gvBalance = depositBalance + earnedPower;

        // withdraw form bribe pot if necessary
        _withdrawFromPot(user, gvAmtToWithdraw, gvBalance);

        _updateDeposits(user, amount);

        _updateTotalSupply(gvAmtToWithdraw);

        _updateDelegated(user, gvAmtToWithdraw, gvBalance);

        uint256 endTime = block.timestamp + withdrawalDelay;
        currRequest.endTime = uint32(endTime);
        currRequest.amount += uint128(amount);
        withdrawRequests[user] = currRequest;

        emit RedeemRequest(user, amount, endTime);
    }

    /// @notice Used to exchange gvToken back to ease token and transfers
    /// pending EASE withdrawal amount to the user if withdrawal delay is over
    function withdrawFinalize() external {
        // Finalize withdraw of a user
        address user = msg.sender;

        WithdrawRequest memory userReq = withdrawRequests[user];
        delete withdrawRequests[user];
        require(
            userReq.endTime <= block.timestamp,
            "withdrawal not yet allowed"
        );

        stakingToken.safeTransfer(user, userReq.amount);

        emit RedeemFinalize(user, userReq.amount);
    }

    /// @notice Stakes percentage of user gvToken to a RCA-vault of choice
    /// @param balancePercent percentage of users balance to
    /// stake to RCA-vault
    /// @param vault RCA-vault address
    function stake(uint256 balancePercent, address vault) external {
        require(rcaController.activeShields(vault), "vault not active");
        address user = msg.sender;

        uint256 totalStake = _totalStaked[user];
        totalStake += balancePercent;

        require(totalStake < MAX_PERCENT, "can't stake more than 100%");

        _totalStaked[user] = totalStake;
        _stakes[vault][user] += balancePercent;

        emit Stake(user, vault, balancePercent);
    }

    /// @notice Unstakes percent share of users balance from RCA-vault
    /// @param balancePercent percentage of users balance to
    /// unstake from RCA-vault
    /// @param vault RCA-vault address
    function unStake(uint256 balancePercent, address vault) external {
        address user = msg.sender;

        _stakes[vault][user] -= balancePercent;
        _totalStaked[user] -= balancePercent;

        emit UnStake(user, vault, balancePercent);
    }

    /// @notice Deposits gvToken of an account to bribe pot
    /// @param amount Amount of gvToken to bribe
    function depositToPot(uint256 amount) external {
        // deposits user gvToken to bribe pot and
        // get rewards against it
        address user = msg.sender;
        uint256 totalPower = balanceOf(user);
        uint256 bribed = bribedAmount[user];

        require(totalPower >= (amount + bribed), "not enough power");

        bribedAmount[user] += amount;

        pot.deposit(user, amount);
    }

    /// @notice Withdraws bribed gvToken from bribe pot
    /// @param amount Amount in gvToken to withdraw from bribe pot
    function withdrawFromPot(uint256 amount) external {
        // withdraws user gvToken from bribe pot
        bribedAmount[msg.sender] -= amount;
        pot.withdraw(msg.sender, amount);
    }

    /// @notice Allows user to collect rewards.
    function claimReward() external {
        pot.getReward(msg.sender, true);
    }

    /// @notice Allows account to claim rewards from Bribe pot and deposit
    /// to gain more gvToken
    function claimAndDepositReward() external {
        address user = msg.sender;
        // bribe rewards from the pot
        uint256 amount;

        PermitArgs memory permit;
        if (bribedAmount[user] > 0) {
            amount = pot.getReward(user, false);
        }
        if (amount > 0) {
            _deposit(user, amount, block.timestamp, permit, true);
        }
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(metadata.name)),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry)
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        address signatory = ecrecover(digest, v, r, s);
        require(
            signatory != address(0),
            "gvEASE::delegateBySig: invalid signature"
        );
        require(
            nonce == nonces[signatory]++,
            "gvEASE::delegateBySig: invalid nonce"
        );
        require(
            block.timestamp <= expiry,
            "gvEASE::delegateBySig: signature expired"
        );
        return _delegate(signatory, delegatee);
    }

    /* ========== ONLY GOV ========== */

    /// @notice Set root for vArmor holders to get earlier deposit start time.
    /// @param root Merkle root of the vArmor holders.
    function setPower(bytes32 root) external onlyGov {
        _powerRoot = root;
    }

    /// @notice Change withdrawal delay
    /// @param time Delay time in seconds
    function setDelay(uint256 time) external onlyGov {
        time = (time / 1 weeks) * 1 weeks;
        require(time > 2 weeks, "min delay 14 days");
        withdrawalDelay = time;
    }

    /// @notice Update total supply for ecosystem wide grown part
    /// @param newTotalSupply New total supply.(should be > existing supply)
    function setTotalSupply(uint256 newTotalSupply) external onlyGov {
        uint256 totalEaseDeposit = totalDeposited;

        require(
            newTotalSupply >= totalEaseDeposit &&
                newTotalSupply <= (totalEaseDeposit * 2),
            "not in range"
        );
        // making sure governance can only update for the vote grown part
        require(newTotalSupply > _totalSupply, "existing > new amount");

        _totalSupply = newTotalSupply;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice EIP-20 token name for this token
    function name() external view returns (string memory) {
        return metadata.name;
    }

    /// @notice EIP-20 token symbol for this token
    function symbol() external view returns (string memory) {
        return metadata.symbol;
    }

    /// @notice EIP-20 token decimals for this token
    function decimals() external view returns (uint8) {
        return uint8(metadata.decimals);
    }

    /// @notice Calculates amount of gvToken staked by user to rca-vault
    /// @param user Address of the staker
    /// @param vault Address of rca-vault
    /// @return Amount of gvToken staked
    function powerStaked(address user, address vault)
        external
        view
        returns (uint256)
    {
        uint256 gvBalance = balanceOf(user);
        uint256 bribed = bribedAmount[user];
        return _percentToGvPower(_stakes[vault][user], gvBalance, bribed);
    }

    ///@notice Calcualtes amount of gvToken that is available for stake
    ///@return Amount of gvToken that is available for staking or bribing
    function powerAvailableForStake(address user)
        external
        view
        returns (uint256)
    {
        uint256 gvBalance = balanceOf(user);
        uint256 bribed = bribedAmount[user];
        uint256 totalStaked = _percentToGvPower(
            _totalStaked[user],
            gvBalance,
            bribed
        );
        return (gvBalance - (totalStaked + bribed));
    }

    /// @notice Get deposits of a user
    /// @param user The address of the account to get the deposits of
    /// @return Details of deposits in an array
    function getUserDeposits(address user)
        external
        view
        returns (Deposit[] memory)
    {
        return _deposits[user];
    }

    /// @notice Total number of tokens in circulation
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Get the number of tokens held by the `account`
    /// @param user The address of the account to get the balance of
    /// @return The number of tokens held
    function balanceOf(address user) public view override returns (uint256) {
        (uint256 depositAmount, uint256 powerEarned) = _balanceOf(user);
        return depositAmount + powerEarned;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    ///@notice Deposit EASE to obtain gvToken that grows upto
    ///twice the amount of ease being deposited.
    ///@param user Wallet address to deposit for
    ///@param amount Amount of EASE to deposit
    ///@param depositStart Start time of deposit(current timestamp
    /// for regular deposit and ahead timestart for vArmor holders)
    ///@param permit v,r,s and deadline for signed approvals (EIP-2612)
    ///@param fromBribePot boolean to represent if reward being deposited
    ///for compounding gvPower
    function _deposit(
        address user,
        uint256 amount,
        uint256 depositStart,
        PermitArgs memory permit,
        bool fromBribePot
    ) internal {
        require(amount > 0, "cannot deposit 0!");

        _updateBalances(user, amount, depositStart);

        // we only transfer tokens from user if they are
        // depositing from their external wallet if this
        // function is called by claimAndDepositReward we don't
        // need to transfer EASE as it will already be transferred
        // to this contract address
        if (!fromBribePot) {
            _transferStakingToken(user, amount, permit);
        }

        emit Deposited(user, amount);
    }

    function _updateBalances(
        address user,
        uint256 amount,
        uint256 depositStart
    ) internal {
        Deposit memory newDeposit = Deposit(
            uint128(amount),
            uint32(depositStart)
        );

        totalDeposited += newDeposit.amount;
        _totalSupply += newDeposit.amount;
        _totalDeposit[user] += newDeposit.amount;
        _deposits[user].push(newDeposit);
    }

    function _transferStakingToken(
        address from,
        uint256 amount,
        PermitArgs memory permit
    ) internal {
        if (permit.r != "") {
            stakingToken.permit(
                from,
                address(this),
                amount,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            );
        }
        stakingToken.safeTransferFrom(from, address(this), amount);
    }

    ///@notice Withraw from bribe pot if withdraw amount of gvToken exceeds
    ///(gvToken balance - bribed amount)
    function _withdrawFromPot(
        address user,
        uint256 gvAmountToWithdraw,
        uint256 userTotalGvBal
    ) internal {
        uint256 totalBribed = bribedAmount[user];
        uint256 gvAmtAvailableForBribe = userTotalGvBal - totalBribed;
        // whether user is willing to withdraw from bribe pot
        // we will not add reward amount to withdraw if user doesn't
        // want to withdraw from bribe pot
        if (totalBribed > 0 && gvAmountToWithdraw > gvAmtAvailableForBribe) {
            uint256 amtToWithdrawFromPot = gvAmountToWithdraw -
                gvAmtAvailableForBribe;
            pot.withdraw(user, amtToWithdrawFromPot);
            bribedAmount[user] -= amtToWithdrawFromPot;
        }
    }

    ///@notice Loops through deposits of user from last index and pop's off the
    ///ones that are included in withdraw amount
    function _updateDeposits(address user, uint256 withdrawAmount) internal {
        Deposit memory remainder;
        uint256 totalAmount;
        // current deposit details
        Deposit memory userDeposit;

        totalDeposited -= withdrawAmount;
        _totalDeposit[user] -= withdrawAmount;
        // index to loop from
        uint256 i = _deposits[user].length;
        for (i; i > 0; i--) {
            userDeposit = _deposits[user][i - 1];
            totalAmount += userDeposit.amount;
            // remove last deposit
            _deposits[user].pop();

            // Let's say user tries to withdraw 100 EASE and they have
            // multiple ease deposits [75, 30] EASE when our loop is
            // at index 0 total amount will be 105, that means we need
            // to push the remainder to deposits array
            if (totalAmount >= withdrawAmount) {
                remainder.amount = uint128(totalAmount - withdrawAmount);
                remainder.start = userDeposit.start;
                break;
            }
        }

        // If there is a remainder we need to update the index at which
        // we broke out of loop and push the withdrawan amount to user
        // _deposits withdraw 100 ease from [75, 30] EASE balance becomes
        // [5]
        if (remainder.amount != 0) {
            _deposits[user].push(remainder);
        }
    }

    ///@notice Updates total supply on withdraw request
    /// @param gvAmtToWithdraw Amount of gvToken to withdraw of a user
    function _updateTotalSupply(uint256 gvAmtToWithdraw) internal {
        // if _totalSupply is not in Sync with the grown votes of users
        // and if it's the last user wanting to get out of this contract
        // we need to take consideration of underflow and at the same time
        // set total supply to zero
        if (_totalSupply < gvAmtToWithdraw || totalDeposited == 0) {
            _totalSupply = 0;
        } else {
            _totalSupply -= gvAmtToWithdraw;
        }
    }

    /// @notice Updates delegated votes of a user on withdraw request.
    /// @param user Address of the user requesting withdraw.
    /// @param withdrawAmt Amount of gvToken being withdrawn.
    /// @param gvBalance Total gvToken balance of a user.
    function _updateDelegated(
        address user,
        uint256 withdrawAmt,
        uint256 gvBalance
    ) internal {
        uint256 remainingGvBal = gvBalance - withdrawAmt;
        uint256 delegatedAmt = _delegated[user];
        // this means we need to deduct delegated Amt
        if (remainingGvBal < delegatedAmt) {
            uint256 gvAmtToDeduct = delegatedAmt - remainingGvBal;
            _delegated[user] -= gvAmtToDeduct;
            _moveDelegates(
                _delegates[msg.sender],
                address(0),
                gvAmtToDeduct,
                0
            );
        }
    }

    function _balanceOf(address user)
        internal
        view
        returns (uint256 depositBalance, uint256 powerEarned)
    {
        uint256 timestamp = block.timestamp;
        depositBalance = _totalDeposit[user];

        uint256 i = _deposits[user].length;
        uint256 depositIncluded;
        for (i; i > 0; i--) {
            Deposit memory userDeposit = _deposits[user][i - 1];

            if ((timestamp - userDeposit.start) > MAX_GROW) {
                // if we reach here that means we have max_grow
                // has been achieved for earlier deposits
                break;
            }

            depositIncluded += userDeposit.amount;
            powerEarned += _powerEarned(userDeposit, timestamp);
        }
        // if we break out of the loop and the user has deposits
        // that have gained max power we need to add that deposit amount
        // to power earned because power can only grow upto deposit amount
        powerEarned += (depositBalance - depositIncluded);
    }

    function _powerEarned(Deposit memory userDeposit, uint256 timestamp)
        private
        pure
        returns (uint256 powerGrowth)
    {
        uint256 timeSinceDeposit = timestamp - userDeposit.start;

        if (timeSinceDeposit < MAX_GROW) {
            powerGrowth =
                (userDeposit.amount *
                    ((timeSinceDeposit * MULTIPLIER) / MAX_GROW)) /
                MULTIPLIER;
        } else {
            powerGrowth = userDeposit.amount;
        }
    }

    function _gvTokenValue(
        uint256 easeAmt,
        uint256 depositBalance,
        uint256 earnedPower
    ) internal pure returns (uint256 gvTokenValue) {
        uint256 conversionRate = (((depositBalance + earnedPower) *
            MULTIPLIER) / depositBalance);
        gvTokenValue = (easeAmt * conversionRate) / MULTIPLIER;
    }

    function _percentToGvPower(
        uint256 stakedPercent,
        uint256 gvBalance,
        uint256 bribed
    ) internal pure returns (uint256 stakedGvPower) {
        stakedGvPower = (stakedPercent * (gvBalance - bribed)) / MAX_PERCENT;
    }
}