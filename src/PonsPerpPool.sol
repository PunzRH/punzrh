// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PerpToken} from "./PerpToken.sol";

interface IUniswapV3Oracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
}

/// @title PonsPerpPool — tokenized long/short PONS exposure, fully collateralized in ETH.
/// @notice "Perpetual pools" design: ETH sits in a LONG pool and a SHORT pool. Every `rebalance()` reads
///         the PONS/WETH TWAP from PONS's own Uniswap v3 pool and moves value from the losing side to the
///         winning side. sPONS (short) and lPONS (long) are plain ERC-20s redeemable pro-rata for their
///         side's ETH — so a memecoin can be paired against sPONS as a live PONS short. No liquidations,
///         no counterparty, no oracle keeper: the price is read straight from the DEX.
///
///         Mints/redeems are two-step (commit, then claim at the NAV of the first rebalance that lands a
///         full TWAP window after the commit) so nobody can front-run the lagging TWAP against holders.
contract PonsPerpPool is Ownable, ReentrancyGuard {
    uint256 private constant Q96 = 2 ** 96;
    uint256 public constant MAX_FEE_BPS = 100; // 1%

    enum Side {
        LONG,
        SHORT
    }

    struct Epoch {
        uint64 time;
        uint256 priceX96; // WETH per PONS, Q96
        uint256 longBal;
        uint256 longSupply;
        uint256 shortBal;
        uint256 shortSupply;
    }

    struct Commit {
        address user;
        Side side;
        bool isBurn;
        bool claimed;
        uint64 time;
        uint256 amount; // ETH (mint) or shares (burn)
    }

    IUniswapV3Oracle public immutable oracle;
    bool public immutable ponsIsToken0;
    uint256 public immutable leverage; // whole number, e.g. 1 or 3
    uint32 public immutable twapWindow; // seconds
    uint32 public immutable rebalanceInterval; // seconds
    PerpToken public immutable longToken;
    PerpToken public immutable shortToken;

    uint256 public longBal; // ETH backing long shares
    uint256 public shortBal; // ETH backing short shares
    uint256 public lastPriceX96;
    uint64 public lastRebalance;
    uint256 public pendingEth; // ETH escrowed for unclaimed mint commits
    uint16 public feeBps; // mint/burn fee to owner

    Epoch[] public epochs;
    Commit[] public commits;

    event Rebalanced(uint256 indexed epoch, uint256 priceX96, uint256 longBal, uint256 shortBal);
    event Committed(uint256 indexed id, address indexed user, Side side, bool isBurn, uint256 amount);
    event Claimed(uint256 indexed id, uint256 indexed epoch, uint256 amountOut);
    event FeeSet(uint16 bps);

    error TooSoon();
    error ZeroAmount();
    error AlreadyClaimed();
    error NotYourCommit();
    error WrongEpoch();
    error FeeTooHigh();
    error NoLiquidity();

    constructor(
        address oracle_,
        address pons_,
        uint256 leverage_,
        uint32 twapWindow_,
        uint32 rebalanceInterval_,
        address owner_
    ) Ownable(owner_) {
        require(leverage_ >= 1 && leverage_ <= 5, "leverage");
        oracle = IUniswapV3Oracle(oracle_);
        ponsIsToken0 = IUniswapV3Oracle(oracle_).token0() == pons_;
        leverage = leverage_;
        twapWindow = twapWindow_;
        rebalanceInterval = rebalanceInterval_;
        string memory lev = _uToStr(leverage_);
        longToken = new PerpToken(string.concat("PONS Long ", lev, "x"), string.concat("l", lev, "PONS"), address(this));
        shortToken = new PerpToken(string.concat("PONS Short ", lev, "x"), string.concat("s", lev, "PONS"), address(this));
        lastPriceX96 = twapPriceX96();
        lastRebalance = uint64(block.timestamp);
        _snapshot();
    }

    // ───────────────────────────── oracle ─────────────────────────────

    /// @return priceX96 WETH per PONS as a Q96 fixed-point number, time-weighted over `twapWindow`.
    function twapPriceX96() public view returns (uint256 priceX96) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        ago[1] = 0;
        (int56[] memory tc,) = oracle.observe(ago);
        int56 delta = tc[1] - tc[0];
        int24 avgTick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && (delta % int56(uint56(twapWindow)) != 0)) avgTick--;
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(avgTick); // sqrt(token1/token0) Q96
        if (ponsIsToken0) {
            // token1 (WETH) per token0 (PONS) = sqrtP^2 / Q96
            priceX96 = FullMath.mulDiv(sqrtP, sqrtP, Q96);
        } else {
            // token1 is PONS: WETH per PONS = 1 / (sqrtP^2 / Q192) = Q288 / sqrtP^2
            priceX96 = FullMath.mulDiv(FullMath.mulDiv(Q96, Q96, sqrtP), Q96, sqrtP);
        }
    }

    // ───────────────────────────── rebalance ─────────────────────────────

    /// @notice Move value between the pools according to the PONS price change since last rebalance.
    ///         Callable by anyone once per `rebalanceInterval`.
    function rebalance() external {
        if (block.timestamp < lastRebalance + rebalanceInterval) revert TooSoon();
        uint256 p = twapPriceX96();
        uint256 p0 = lastPriceX96;
        // value only moves toward a side that has shareholders to receive it (never strand ETH)
        if (p > p0 && shortBal > 0 && longToken.totalSupply() > 0) {
            // PONS up: shorts pay longs. T = S * (1 - (p0/p)^lev)
            uint256 r = Q96;
            for (uint256 i = 0; i < leverage; i++) r = FullMath.mulDiv(r, p0, p);
            uint256 t = shortBal - FullMath.mulDiv(shortBal, r, Q96);
            shortBal -= t;
            longBal += t;
        } else if (p < p0 && longBal > 0 && shortToken.totalSupply() > 0) {
            // PONS down: longs pay shorts. T = L * (1 - (p/p0)^lev)
            uint256 r = Q96;
            for (uint256 i = 0; i < leverage; i++) r = FullMath.mulDiv(r, p, p0);
            uint256 t = longBal - FullMath.mulDiv(longBal, r, Q96);
            longBal -= t;
            shortBal += t;
        }
        lastPriceX96 = p;
        lastRebalance = uint64(block.timestamp);
        _snapshot();
        emit Rebalanced(epochs.length - 1, p, longBal, shortBal);
    }

    function _snapshot() internal {
        epochs.push(
            Epoch({
                time: uint64(block.timestamp),
                priceX96: lastPriceX96,
                longBal: longBal,
                longSupply: longToken.totalSupply(),
                shortBal: shortBal,
                shortSupply: shortToken.totalSupply()
            })
        );
    }

    // ───────────────────────────── commit / claim ─────────────────────────────

    /// @notice Deposit ETH to mint shares of `side`. Claim after the first rebalance that lands a full TWAP
    ///         window after this commit.
    function commitMint(Side side) external payable returns (uint256 id) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee = msg.value * feeBps / 10_000;
        uint256 amount = msg.value - fee;
        if (fee > 0) _send(owner(), fee);
        pendingEth += amount;
        id = commits.length;
        commits.push(Commit(msg.sender, side, false, false, uint64(block.timestamp), amount));
        emit Committed(id, msg.sender, side, false, amount);
    }

    /// @notice Escrow shares of `side` to redeem for ETH. Same claim timing as mints.
    function commitBurn(Side side, uint256 shares) external returns (uint256 id) {
        if (shares == 0) revert ZeroAmount();
        _token(side).transferFrom(msg.sender, address(this), shares);
        id = commits.length;
        commits.push(Commit(msg.sender, side, true, false, uint64(block.timestamp), shares));
        emit Committed(id, msg.sender, side, true, shares);
    }

    /// @notice Settle commit `id` at epoch `e` — the first epoch whose time >= commit.time + twapWindow.
    function claim(uint256 id, uint256 e) external nonReentrant returns (uint256 out) {
        Commit storage c = commits[id];
        if (c.claimed) revert AlreadyClaimed();
        if (c.user != msg.sender) revert NotYourCommit();
        uint64 horizon = c.time + twapWindow;
        Epoch storage ep = epochs[e];
        if (ep.time < horizon) revert WrongEpoch();
        if (e > 0 && epochs[e - 1].time >= horizon) revert WrongEpoch();
        c.claimed = true;

        (uint256 bal, uint256 supply) = c.side == Side.LONG ? (ep.longBal, ep.longSupply) : (ep.shortBal, ep.shortSupply);
        PerpToken tok = _token(c.side);

        if (!c.isBurn) {
            // shares at epoch NAV; first-ever shares priced so that 1 share ~= 1 PONS of value
            if (supply == 0 || bal == 0) {
                uint256 priceWei = FullMath.mulDiv(ep.priceX96, 1e18, Q96);
                out = FullMath.mulDiv(c.amount, 1e18, priceWei == 0 ? 1 : priceWei);
            } else {
                out = FullMath.mulDiv(c.amount, supply, bal);
            }
            pendingEth -= c.amount;
            if (c.side == Side.LONG) longBal += c.amount;
            else shortBal += c.amount;
            tok.mint(c.user, out);
        } else {
            if (supply == 0 || bal == 0) revert NoLiquidity();
            out = FullMath.mulDiv(c.amount, bal, supply);
            uint256 sideBal = c.side == Side.LONG ? longBal : shortBal;
            if (out > sideBal) out = sideBal; // NAV drifted since snapshot; never over-pay the side
            if (c.side == Side.LONG) longBal -= out;
            else shortBal -= out;
            tok.burn(address(this), c.amount);
            uint256 fee = out * feeBps / 10_000;
            if (fee > 0) _send(owner(), fee);
            _send(c.user, out - fee);
        }
        emit Claimed(id, e, out);
    }

    // ───────────────────────────── views ─────────────────────────────

    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    function commitCount() external view returns (uint256) {
        return commits.length;
    }

    /// @notice First epoch index at which commit `id` is claimable, or type(uint256).max if not yet.
    function claimableEpoch(uint256 id) external view returns (uint256) {
        uint64 horizon = commits[id].time + twapWindow;
        for (uint256 i = 0; i < epochs.length; i++) {
            if (epochs[i].time >= horizon) return i;
        }
        return type(uint256).max;
    }

    /// @notice Current ETH value (wei) of one whole share (1e18) of `side`.
    function sharePriceWei(Side side) external view returns (uint256) {
        (uint256 bal, uint256 supply) = side == Side.LONG
            ? (longBal, longToken.totalSupply())
            : (shortBal, shortToken.totalSupply());
        if (supply == 0) return 0;
        return FullMath.mulDiv(bal, 1e18, supply);
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setFee(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = bps;
        emit FeeSet(bps);
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _token(Side side) internal view returns (PerpToken) {
        return side == Side.LONG ? longToken : shortToken;
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send");
    }

    function _uToStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v > 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }
}
