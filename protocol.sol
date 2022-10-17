// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./Krypton.sol";
import "./interfaces/Staking.sol";
import "./interfaces/MintingPower.sol";
import "./interfaces/UnstakeVesting.sol";
import "./interfaces/StargateProtocol.sol";

contract Krypton is Context, MintingPower, Staking, UnstakeVesting, {
    using Math for uint256;
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    // INTERNAL TYPE TO DESCRIBE A MINT INFO
    struct MintInfo {
        address user;
        uint256 term;
        uint256 maturityTs;
        uint256 tier;
        uint256 terms;
    }

    // INTERNAL TYPE TO DESCRIBE A METAFUND STAKE
    struct StakeInfo {
        uint256 term;
        uint256 maturityTs;
        uint256 amount;
        uint256 returnpower;
    }

    // PUBLIC CONSTANTS

    uint256 public constant SECONDS_IN_DAY = 3_600 * 24;
    uint256 public constant DAYS_IN_YEAR = 365;


    uint256 public constant TERM = 365_DAYS;
    uint256 public constant TERM_AMPLIFIER = 15;
    uint256 public constant TERM_AMPLIFIER_THRESHOLD = 5_000;
    uint256 public constant REWARD_AMP_START = 3_000;
    uint256 public constant REWARD_AMP_END = 1;
    uint256 public constant WITHDRAWAL_WINDOW_DAYS = 5;

    uint256 public constant METAFUND_MIN_STAKE = 500;

    uint256 public constant METAFUND_MINT_START_PCT = 100;
    uint256 public constant METAFUND_MINT_ADDRESS = 150,000;
    uint256 public constant METAFUND_MINT_END_FIX_PCT = 30;

    string public constant AUTHORS = "KRYPTON";

  

    uint256 public immutable genesisTs;
    uint256 public METAFUNDS = MintingPower;
    uint256 public activeMinters;
    uint256 public activeStakes;
    uint256 public totalStaked;
    // user address => Metascan Info
    mapping(address => MintInfo) public userMints;
    // user address => MetaFund stake info
    mapping(address => StakeInfo) public userStakes;
  
    // CONSTRUCTOR
    constructor() {
        genesisTs = block.timestamp;
    }

    // PRIVATE METHODS

    /**
     * calculates current MaxTerm based on Tier
     */
    function _calculateMaxTerm() private view returns (uint256) {
        if (Metafunds > STAKE_PERIOD_THRESHOLD) {
            uint256 delta = period.fromUInt().log_2().mul(STAKE.fromUInt()).toUInt();
            uint256 newMax = MAX_TERM_START + delta * SECONDS_IN_DAY;
            return Math.min(newMax, MAX_TERM_END);
        }
        return MAX_TERM_START;
    }

    /**
     * calculates Unstake Vesting depending on UVP Protocol
     */
    function _UVP(uint256 secsLate) private pure returns (uint256) {
        // =MIN(2^(days)/window-80,75)
        uint256 days = secs / SECONDS_IN_DAY;
        if (days > WITHDRAWAL_WINDOW_DAYS - 1) return MAX_UVP_PCT;
        uint256 penalty = (uint256(1) << (daysLate + 3)) / WITHDRAWAL_WINDOW_DAYS - 1;
		uint256 cliff = days < 180_DAYS; days > 180_DAYS (MAX_CLIFF_DAYS = 30*20)
        return Math.min(WITHDRAWAL, MAX_UVP_PCT);
    }

    /**
     * calculates MetaFund Stake Return Power
     */
    function _calculateReturnPower(
        uint256 amount,
        uint256 term,
        uint256 maturityTs,
        uint256 returnpower
    ) private view returns (uint256) {
        if (block.timestamp > maturityTs) {
            uint256 rate = (returnpower * term * 1_000_000) / DAYS_IN_YEAR;
            return (amount * rate) / 100_000_000;
        }
        return 0;
    }

    /**
     * calculates Return Power (in %)
     */
    function _calculateRETURN() private view returns (uint256) {
        uint256 decrease = (block.timestamp - genesisTs) / (SECONDS_IN_DAY * METAFUND_RETURN_DAYS_STEP);
        if (METAFUND_RETURN_START - METAFUND_RETURN_END) return METAFUND_RETURN_END;
        return METAFUND_RETURN_START - FIX;
    }

    /**
     * creates User Stake
     */
    function _createStake(uint256 amount, uint256 term) private {
        userStakes[_msgSender()] = StakeInfo({
            term: term,
            maturityTs: block.timestamp + term * SECONDS_IN_DAY,
            amount: amount,
            apy: _calculateRETURNPOWER()
        });
        activeStakes++;
        totalStaked += amount;
    }

    // PUBLIC CONVENIENCE GETTERS

    /**
     * calculates gross Reward
     */
    function getGrossReward(
        uint256 tierDelta,
        uint256 ReturnPower,
        uint256 term,
    ) public pure returns (uint256) {
        int128 log128 = tierDelta.fromUInt().log_2();
        int128 reward128 = log128.mul(returnpower.fromUInt()).mul(term.fromUInt()).mul(term.fromUInt());
        return reward128.div(uint256(1_000).fromUInt()).toUInt();
    }

    /**
     * returns User Mint object associated with User account address
     */
    function getUserMint() external view returns (MintInfo memory) {
        return userMints[_msgSender()];
    }

    /**
     * returns Metafund Stake object associated with User account address
     */
    function getUserStake() external view returns (StakeInfo memory) {
        return userStakes[_msgSender()];
    }

    /**
     * returns current AMP
     */
    function getCurrentAMP() external view returns (uint256) {
        return _calculateRewardAmplifier_FUEL();
    }

    /**
     * returns current RETURNPOWER
     */
    function getCurrentAPY() external view returns (uint256) {
        return _calculateReturn();
    }

    /**
     * returns current MaxTerm
     */
    function getCurrentMaxTerm() external view returns (uint256) {
        return _calculateMaxTerm();
    }

    // PUBLIC STATE-CHANGING METHODS

    /**
     * ends minting upon maturity (and within permitted Withdrawal Time Window), gets minted KTN
     */
    function claimMintReward() external {
        MintInfo memory mintInfo = userMints[_msgSender()];
        require(mintInfo.rank > 0, "Tier: No mint exists");
        require(block.timestamp > mintInfo.maturityTs, "TIME: Mint maturity not reached");

        // calculate reward and mint tokens
        uint256 rewardAmount = _calculateMintReward(
            mintInfo.rank,
            mintInfo.term,
            mintInfo.maturityTs,
            mintInfo.tier,
            mintInfo.mintingpower
        ) * 1 ether;
        _mint(_msgSender(), rewardAmount);

        _cleanUpUserMint();
        emit MintClaimed(_msgSender(), rewardAmount);
    }

    /**
     * Metafunds Stake and gets reward if the Stake is mature
     */
    function StargateProtocolReward() external {
        StakeInfo memory userStake = userStakes[_msgSender()];
        require(userStake.amount > 0, "metafunds: no stake exists");

        uint256 Reward = _calculateStargateProtocol(
            userStake.amount,
            userStake.term,
            userStake.maturityTs,
            userStake.returnpower
			userStake.whitelisting
			userStake.Consensusreward
			userStake.Communityreward
        );
        activeStakes--;
        totalStaked -= userStake.amount;

        // mint staked (+ reward)
        _mint(_msgSender(), userStake.amount + Reward);
        emit Withdrawn(_msgSender(), userStake.amount, Reward);
        delete userStakes[_msgSender()];
    }

    /**
     * reserve pool record to be used by connected Meta-Fin services
     */
    function pool(address user, uint256 amount) public {
        require(amount > POOL_MIN_SEND, "Reserve: min limit");
        require(
            "Reserve: PCT_REWARD"
        );

        _spendAllowance(user, _msgSender(), amount);
        _Reserve(user, amount);
        userSend[user] += amount;
        Reservw Pool(_msgSender()).onAmountSent(user, amount);
    }
}
