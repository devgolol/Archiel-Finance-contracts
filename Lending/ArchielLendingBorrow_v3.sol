// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ArchielLendingBorrow v3  —  Multi-Collateral, Single Lending (USDC)   ║
// ║                                                                          ║
// ║  Collateral  : any ERC-20 added by owner (cirBTC, ARCL, REGAR, EURC…)  ║
// ║  Lending     : USDC (immutable, 1 token only)                           ║
// ║  Oracle      : Pyth per collateral + manual fallback per collateral      ║
// ║  Interest    : per-collateral borrow APR / supply APY global (USDC)     ║
// ║                                                                          ║
// ║  v3 Fixes:                                                               ║
// ║  [1] Dynamic locked collateral on withdraw (real-time price)            ║
// ║  [2] Yield preserved on top-up (accumulated yield tracker)              ║
// ║  [3] addCollateral checks decimals==0 instead of !enabled               ║
// ║  [4] emergencyWithdraw for owner                                         ║
// ║  [5] supplyApy change emits event; rate documented as retroactive        ║
// ║  [6] Partial repayLoan support                                           ║
// ║  [7] borrowApr/supplyApy conflict guard on setSupplyApy                 ║
// ║  [8] removeCollateral (safe, disables + purges from list)               ║
// ║  [9] Duplicate guard in addCollateral via decimals==0 check             ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// ── Pyth Network interfaces ───────────────────────────────────────────────
struct PythPrice {
    int64  price;
    uint64 conf;
    int32  expo;
    uint   publishTime;
}

interface IPyth {
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (PythPrice memory);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

// ─────────────────────────────────────────────────────────────────────────────

contract ArchielLendingBorrowV3 is Ownable {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS_DENOM        = 10_000;

    // ── Lending token (USDC — immutable) ──────────────────────────────────
    IERC20  public immutable usdcToken;
    uint8   public immutable usdcDecimals; // e.g. 6 or 8

    // ── Supply (lender) state — USDC side ─────────────────────────────────
    /// @notice Annual yield paid to USDC suppliers. Default 8% = 800 bps.
    uint256 public supplyApy = 800;

    struct Supply {
        uint256 amount;           // USDC principal deposited (excluding accumulated yield)
        uint256 accumulatedYield; // [FIX-2] yield earned and not yet withdrawn, checkpointed on every deposit
        uint256 depositedAt;      // timestamp of last deposit / yield checkpoint
    }
    mapping(address => Supply) public supplies;
    uint256 public totalSupplied;

    // ══════════════════════════════════════════════════════════════════════
    //  COLLATERAL REGISTRY
    // ══════════════════════════════════════════════════════════════════════

    struct CollateralInfo {
        bool    enabled;
        uint8   decimals;
        string  symbol;

        // LTV & price
        uint256 collateralFactor;    // LTV %, e.g. 70 = 70%
        uint256 manualPriceUsdc;     // fallback price scaled to 1e8

        // Per-collateral borrow APR
        uint256 borrowApr;           // in bps, e.g. 1000 = 10%

        // Pyth oracle (optional per collateral)
        address pythAddress;
        bytes32 pythFeedId;
        uint256 pythMaxAge;
    }

    // token address → collateral config
    mapping(address => CollateralInfo) public collaterals;
    // ordered list of supported collateral addresses
    address[] public collateralList;

    // ── Per-user, per-collateral balances & loans ──────────────────────────

    // user → collateral → deposited amount
    mapping(address => mapping(address => uint256)) public collateralBalances;

    struct Loan {
        address collateralToken; // which token is used as collateral
        uint256 principal;       // USDC borrowed
        uint256 collateralAmt;   // total collateral balance at borrow time (snapshot)
        uint256 openedAt;        // timestamp
        bool    isActive;
    }
    // user → loan (one active loan per user; must repay before taking new)
    mapping(address => Loan) public loans;

    // ── Events ────────────────────────────────────────────────────────────
    event CollateralAdded(address indexed token, string symbol, uint256 factor, uint256 borrowApr);
    event CollateralUpdated(address indexed token, uint256 factor, uint256 manualPrice, uint256 borrowApr);
    event CollateralEnabled(address indexed token, bool enabled);
    event CollateralRemoved(address indexed token);                          // [FIX-8]
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event LoanTaken(address indexed user, address indexed collateralToken, uint256 principal);
    event LoanRepaid(address indexed user, uint256 repaidAmount, uint256 interestPaid, bool fullyClosed); // [FIX-6]
    event UsdcSupplied(address indexed user, uint256 amount);
    event UsdcWithdrawn(address indexed user, uint256 amount, uint256 yieldIncluded);
    event PoolFunded(uint256 amount);
    event SupplyApyUpdated(uint256 oldApy, uint256 newApy);                 // [FIX-5]
    event PythOracleSet(address indexed token, address pyth, bytes32 feedId, uint256 maxAge);
    event EmergencyWithdraw(address indexed token, uint256 amount);         // [FIX-4]

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(
        address _usdcToken,
        uint8   _usdcDecimals
    ) Ownable(msg.sender) {
        require(_usdcToken != address(0), "Invalid USDC address");
        usdcToken    = IERC20(_usdcToken);
        usdcDecimals = _usdcDecimals;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  OWNER — COLLATERAL MANAGEMENT
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Register a new collateral token.
    /// @param token          ERC-20 address
    /// @param symbol         e.g. "cirBTC"
    /// @param decimals       token decimals
    /// @param factor         LTV %, 1–100
    /// @param manualPrice    fallback price in USDC scaled to 1e8
    ///                       e.g. cirBTC at $64,000 → 6400000000000 (6.4e12)
    /// @param borrowAprBps   borrow APR in bps (e.g. 1000 = 10%)
    function addCollateral(
        address token,
        string  calldata symbol,
        uint8   decimals,
        uint256 factor,
        uint256 manualPrice,
        uint256 borrowAprBps
    ) external onlyOwner {
        require(token != address(0),                      "Invalid token");
        // [FIX-3 & FIX-9] Use decimals==0 as the "not yet registered" sentinel.
        // This prevents re-registration of a previously disabled token AND
        // avoids duplicate pushes to collateralList.
        require(collaterals[token].decimals == 0,         "Already registered");
        require(decimals > 0,                             "Decimals must be > 0");
        require(factor > 0 && factor <= 100,              "Factor 1-100");
        require(manualPrice > 0,                          "Price must be > 0");
        require(borrowAprBps > 0 && borrowAprBps <= 5000, "APR 1-5000 bps");
        require(borrowAprBps > supplyApy,                 "borrowApr must be > supplyApy");

        collaterals[token] = CollateralInfo({
            enabled:          true,
            decimals:         decimals,
            symbol:           symbol,
            collateralFactor: factor,
            manualPriceUsdc:  manualPrice,
            borrowApr:        borrowAprBps,
            pythAddress:      address(0),
            pythFeedId:       bytes32(0),
            pythMaxAge:       60
        });
        collateralList.push(token);
        emit CollateralAdded(token, symbol, factor, borrowAprBps);
    }

    /// @notice Update LTV, manual price, and borrow APR for an existing collateral.
    function updateCollateral(
        address token,
        uint256 factor,
        uint256 manualPrice,
        uint256 borrowAprBps
    ) external onlyOwner {
        require(collaterals[token].decimals > 0, "Not registered");
        require(factor > 0 && factor <= 100,     "Factor 1-100");
        require(manualPrice > 0,                 "Price must be > 0");
        require(borrowAprBps > 0 && borrowAprBps <= 5000, "APR 1-5000 bps");
        require(borrowAprBps > supplyApy,        "borrowApr must be > supplyApy");

        CollateralInfo storage c = collaterals[token];
        c.collateralFactor  = factor;
        c.manualPriceUsdc   = manualPrice;
        c.borrowApr         = borrowAprBps;
        emit CollateralUpdated(token, factor, manualPrice, borrowAprBps);
    }

    /// @notice Enable or disable a collateral token (does not remove existing deposits).
    function setCollateralEnabled(address token, bool enabled) external onlyOwner {
        require(collaterals[token].decimals > 0, "Not registered");
        collaterals[token].enabled = enabled;
        emit CollateralEnabled(token, enabled);
    }

    /// @notice [FIX-8] Safely remove a collateral from the registry and collateralList.
    ///         The token must first be disabled. Existing user balances are untouched
    ///         (users can still withdraw their collateral via withdrawCollateral).
    ///         This resets the decimals sentinel to 0, allowing re-registration later.
    function removeCollateral(address token) external onlyOwner {
        CollateralInfo storage c = collaterals[token];
        require(c.decimals > 0,  "Not registered");
        require(!c.enabled,      "Disable collateral before removing");

        // Remove from collateralList (swap-and-pop)
        uint256 len = collateralList.length;
        for (uint256 i = 0; i < len; i++) {
            if (collateralList[i] == token) {
                collateralList[i] = collateralList[len - 1];
                collateralList.pop();
                break;
            }
        }
        // Reset struct so decimals sentinel returns to 0 (allows re-add later)
        delete collaterals[token];
        emit CollateralRemoved(token);
    }

    /// @notice Set Pyth oracle for a specific collateral token.
    function setPythOracle(
        address token,
        address pythAddr,
        bytes32 feedId,
        uint256 maxAge
    ) external onlyOwner {
        require(collaterals[token].decimals > 0, "Not registered");
        require(maxAge > 0, "maxAge must be > 0");
        if (pythAddr != address(0)) {
            try IPyth(pythAddr).getUpdateFee(new bytes[](0)) returns (uint256) {}
            catch { revert("Not a valid Pyth address"); }
        }
        CollateralInfo storage c = collaterals[token];
        c.pythAddress = pythAddr;
        c.pythFeedId  = feedId;
        c.pythMaxAge  = maxAge;
        emit PythOracleSet(token, pythAddr, feedId, maxAge);
    }

    /// @notice [FIX-5 & FIX-7] Set global supply APY for USDC lenders.
    ///         - Emits old + new APY for transparency.
    ///         - Guards against APY >= any existing collateral's borrowApr.
    ///         - NOTE: Rate change is retroactive (affects existing suppliers' yield
    ///           calculation from their last checkpoint). Call setSupplyApy before
    ///           large lender activity to minimise unintended retroactive effect.
    function setSupplyApy(uint256 _supplyApy) external onlyOwner {
        require(_supplyApy < 5000, "APY must be < 5000 bps");

        // [FIX-7] Ensure new APY does not exceed or equal any registered borrowApr.
        uint256 len = collateralList.length;
        for (uint256 i = 0; i < len; i++) {
            CollateralInfo storage c = collaterals[collateralList[i]];
            if (c.decimals > 0) {
                require(
                    _supplyApy < c.borrowApr,
                    "APY must be < borrowApr of all registered collaterals"
                );
            }
        }

        emit SupplyApyUpdated(supplyApy, _supplyApy); // [FIX-5]
        supplyApy = _supplyApy;
    }

    /// @notice Owner funds the USDC lending pool.
    function fundPool(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(amount);
    }

    /// @notice [FIX-4] Emergency rescue of any ERC-20 token (or USDC) from the contract.
    ///         Use with care — only for genuine emergencies or contract migration.
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(token, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PRICE HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function getCollateralPrice(address token) public view returns (uint256) {
        CollateralInfo storage c = collaterals[token];
        (bool ok, uint256 price) = _tryGetPythPrice(c);
        return ok ? price : c.manualPriceUsdc;
    }

    function isPythLive(address token) external view returns (bool ok) {
        (ok,) = _tryGetPythPrice(collaterals[token]);
    }

    function _tryGetPythPrice(CollateralInfo storage c)
        internal view returns (bool ok, uint256 price)
    {
        if (c.pythAddress == address(0) || c.pythFeedId == bytes32(0)) return (false, 0);
        try IPyth(c.pythAddress).getPriceNoOlderThan(c.pythFeedId, c.pythMaxAge)
            returns (PythPrice memory p)
        {
            if (p.price <= 0) return (false, 0);
            uint256 raw = uint256(uint64(p.price));
            int32   expo = p.expo;
            uint256 normalized;
            if      (expo == -8) normalized = raw;
            else if (expo > -8)  normalized = raw * (10 ** uint32(expo + 8));
            else                 normalized = raw / (10 ** uint32(-8 - expo));
            if (normalized == 0) return (false, 0);
            return (true, normalized);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Convert a raw collateral amount to USDC value (both in their native decimals).
    ///      Price is scaled 1e8. Result is in USDC native decimals.
    function collateralValueUsdc(address token, uint256 amount)
        public view returns (uint256)
    {
        CollateralInfo storage c = collaterals[token];
        uint256 price = getCollateralPrice(token);
        uint256 rawValue = (amount * price) / (10 ** 8);
        if (c.decimals >= usdcDecimals) {
            return rawValue / (10 ** (c.decimals - usdcDecimals));
        } else {
            return rawValue * (10 ** (usdcDecimals - c.decimals));
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  INTEREST MATH
    // ══════════════════════════════════════════════════════════════════════

    function accruedInterest(address user) public view returns (uint256) {
        Loan storage loan = loans[user];
        if (!loan.isActive || loan.principal == 0) return 0;
        uint256 apr     = collaterals[loan.collateralToken].borrowApr;
        uint256 elapsed = block.timestamp - loan.openedAt;
        return (loan.principal * apr * elapsed) / (SECONDS_PER_YEAR * BPS_DENOM);
    }

    function totalOwed(address user) public view returns (uint256) {
        Loan storage loan = loans[user];
        if (!loan.isActive) return 0;
        return loan.principal + accruedInterest(user);
    }

    /// @dev [FIX-2] Returns yield accrued since last checkpoint only (on top of accumulatedYield).
    function _pendingYield(address user) internal view returns (uint256) {
        Supply storage s = supplies[user];
        if (s.amount == 0 || s.depositedAt == 0) return 0;
        uint256 elapsed = block.timestamp - s.depositedAt;
        return (s.amount * supplyApy * elapsed) / (SECONDS_PER_YEAR * BPS_DENOM);
    }

    /// @notice Total yield available to a lender = accumulated checkpoint + pending since last deposit.
    function accruedYield(address user) public view returns (uint256) {
        return supplies[user].accumulatedYield + _pendingYield(user);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  COLLATERAL — deposit & withdraw
    // ══════════════════════════════════════════════════════════════════════

    function depositCollateral(address token, uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        CollateralInfo storage c = collaterals[token];
        require(c.enabled, "Collateral not supported");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collateralBalances[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice [FIX-1] Withdraw unlocked collateral.
    ///         "Locked" amount is calculated dynamically from current price so that
    ///         if collateral value has risen, excess can be withdrawn immediately.
    function withdrawCollateral(address token, uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        uint256 locked = 0;
        if (loans[msg.sender].isActive && loans[msg.sender].collateralToken == token) {
            // [FIX-1] Minimum collateral needed to keep the loan healthy (cover 100% of owed).
            // Use current live price so that price increases free up collateral.
            uint256 owed = totalOwed(msg.sender);
            CollateralInfo storage c = collaterals[token];
            uint256 price = getCollateralPrice(token);
            if (price > 0 && owed > 0) {
                // locked = owed (in token units), rounded up, with decimal adjustment
                // rawLocked in token decimals = owed (usdc decimals) * 1e8 / price
                uint256 rawLocked;
                if (c.decimals >= usdcDecimals) {
                    rawLocked = (owed * (10 ** (c.decimals - usdcDecimals)) * (10 ** 8)) / price;
                } else {
                    rawLocked = (owed * (10 ** 8)) / (price * (10 ** (usdcDecimals - c.decimals)));
                }
                // Add 1 wei of collateral-token as rounding buffer
                locked = rawLocked + 1;
            } else {
                // Fallback: lock everything if price is unavailable
                locked = collateralBalances[msg.sender][token];
            }
        }

        uint256 userBal  = collateralBalances[msg.sender][token];
        uint256 available = locked >= userBal ? 0 : userBal - locked;
        require(amount <= available, "Insufficient available collateral");
        collateralBalances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  BORROW — takeLoan & repayLoan
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Borrow USDC against a supported collateral token.
    /// @param collateralToken  which collateral to use (must be deposited)
    /// @param amount           USDC amount to borrow (in USDC decimals)
    function takeLoan(address collateralToken, uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        require(!loans[msg.sender].isActive, "Repay existing loan first");
        CollateralInfo storage c = collaterals[collateralToken];
        require(c.enabled, "Collateral not supported");

        uint256 colBal = collateralBalances[msg.sender][collateralToken];
        require(colBal > 0, "No collateral deposited for this token");

        uint256 maxBorrowAmt = (collateralValueUsdc(collateralToken, colBal) * c.collateralFactor) / 100;
        require(amount <= maxBorrowAmt, "Exceeds borrow limit");
        require(usdcToken.balanceOf(address(this)) >= amount, "Insufficient pool liquidity");

        loans[msg.sender] = Loan({
            collateralToken: collateralToken,
            principal:       amount,
            collateralAmt:   colBal,    // snapshot for reference; locking is dynamic in v3
            openedAt:        block.timestamp,
            isActive:        true
        });

        usdcToken.safeTransfer(msg.sender, amount);
        emit LoanTaken(msg.sender, collateralToken, amount);
    }

    /// @notice [FIX-6] Repay all or part of the outstanding loan.
    ///         Interest is applied proportionally for partial repayments.
    ///         Loan is closed automatically once principal reaches zero.
    /// @param amount  USDC to repay. Pass type(uint256).max to repay the full amount.
    function repayLoan(uint256 amount) external {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 interest = accruedInterest(msg.sender);
        uint256 fullOwed = loan.principal + interest;

        // Clamp to full amount if caller passes max sentinel
        if (amount > fullOwed) amount = fullOwed;
        require(amount > 0, "Amount must be > 0");

        // Split payment: interest first, then principal
        uint256 interestPaid;
        uint256 principalPaid;
        if (amount >= interest) {
            interestPaid  = interest;
            principalPaid = amount - interest;
        } else {
            // Partial payment covers only part of the interest
            interestPaid  = amount;
            principalPaid = 0;
        }

        usdcToken.safeTransferFrom(msg.sender, address(this), amount);

        bool fullyClosed = (principalPaid >= loan.principal);
        if (fullyClosed) {
            emit LoanRepaid(msg.sender, amount, interestPaid, true);
            loan.principal     = 0;
            loan.collateralAmt = 0;
            loan.isActive      = false;
        } else {
            // Reset openedAt so future interest accrues only on remaining principal
            loan.principal -= principalPaid;
            loan.openedAt   = block.timestamp;
            emit LoanRepaid(msg.sender, amount, interestPaid, false);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SUPPLY — supplyUsdc & withdrawUsdc (lender side)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice [FIX-2] Supply USDC to the lending pool.
    ///         Yield earned since the last deposit is checkpointed into
    ///         accumulatedYield before the new deposit is recorded, so
    ///         prior earnings are never lost on top-up.
    function supplyUsdc(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        Supply storage s = supplies[msg.sender];

        // Checkpoint: move pending yield into accumulated bucket
        if (s.amount > 0 && s.depositedAt > 0) {
            uint256 pending = _pendingYield(msg.sender);
            s.accumulatedYield += pending;
        }

        usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        s.amount      += amount;
        s.depositedAt  = block.timestamp; // only resets the per-second counter, not accumulated
        totalSupplied += amount;
        emit UsdcSupplied(msg.sender, amount);
    }

    /// @notice [FIX-2] Withdraw up to (principal + all accumulated + pending yield).
    ///         Partial withdrawal supported; principal is drawn down first.
    function withdrawUsdc(uint256 amount) external {
        Supply storage s = supplies[msg.sender];
        require(s.amount > 0, "No active supply");

        uint256 totalYield    = accruedYield(msg.sender); // accumulated + pending
        uint256 totalWithdraw = s.amount + totalYield;
        require(amount <= totalWithdraw,                       "Exceeds supply + yield");
        require(usdcToken.balanceOf(address(this)) >= amount, "Insufficient pool liquidity");

        // Snapshot principal before mutation so we can calculate yieldTaken correctly
        uint256 principalBefore = s.amount;

        // Deduct from principal first, then overflow into yield
        if (amount <= principalBefore) {
            s.amount      -= amount;
            totalSupplied -= amount;
            // No yield consumed — just checkpoint accumulated so timer resets cleanly
            s.accumulatedYield = totalYield;
        } else {
            // Entire principal consumed; remainder comes from yield
            uint256 yieldTaken = amount - principalBefore;
            totalSupplied     -= principalBefore;
            s.amount           = 0;
            s.accumulatedYield = totalYield > yieldTaken ? totalYield - yieldTaken : 0;
        }

        if (s.amount == 0 && s.accumulatedYield == 0) {
            // Position fully closed — reset everything
            s.depositedAt = 0;
        } else {
            // Restart the per-second yield counter from now
            s.depositedAt = block.timestamp;
        }

        usdcToken.safeTransfer(msg.sender, amount);
        emit UsdcWithdrawn(msg.sender, amount, totalYield);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Max USDC a user can borrow using a specific collateral token.
    function maxBorrow(address user, address token) external view returns (uint256) {
        if (loans[user].isActive) return 0;
        CollateralInfo storage c = collaterals[token];
        if (!c.enabled) return 0;
        uint256 bal = collateralBalances[user][token];
        return (collateralValueUsdc(token, bal) * c.collateralFactor) / 100;
    }

    /// @notice Available (unlocked) collateral for a user — uses dynamic locking (FIX-1).
    function availableCollateral(address user, address token) external view returns (uint256) {
        uint256 userBal = collateralBalances[user][token];
        if (!loans[user].isActive || loans[user].collateralToken != token) return userBal;

        uint256 owed = totalOwed(user);
        CollateralInfo storage c = collaterals[token];
        uint256 price = getCollateralPrice(token);
        if (price == 0 || owed == 0) return 0;

        uint256 rawLocked;
        if (c.decimals >= usdcDecimals) {
            rawLocked = (owed * (10 ** (c.decimals - usdcDecimals)) * (10 ** 8)) / price;
        } else {
            rawLocked = (owed * (10 ** 8)) / (price * (10 ** (usdcDecimals - c.decimals)));
        }
        uint256 locked = rawLocked + 1;
        return locked >= userBal ? 0 : userBal - locked;
    }

    /// @notice Health factor × 100 (e.g. 150 = 1.5x).
    ///         Returns type(uint256).max if no active loan.
    function healthFactor(address user) external view returns (uint256) {
        Loan storage loan = loans[user];
        if (!loan.isActive) return type(uint256).max;
        uint256 owed = loan.principal + accruedInterest(user);
        if (owed == 0) return type(uint256).max;
        uint256 colValue = collateralValueUsdc(loan.collateralToken, collateralBalances[user][loan.collateralToken]);
        return (colValue * 100) / owed;
    }

    function poolLiquidity() external view returns (uint256) {
        return usdcToken.balanceOf(address(this));
    }

    /// @notice Full loan info for a user.
    function loanInfo(address user) external view returns (
        address colToken,
        uint256 principal,
        uint256 interest,
        uint256 total,
        uint256 colAmount,
        uint256 openedAt,
        bool    isActive
    ) {
        Loan storage loan = loans[user];
        colToken   = loan.collateralToken;
        principal  = loan.principal;
        interest   = accruedInterest(user);
        total      = principal + interest;
        colAmount  = collateralBalances[user][loan.collateralToken]; // live balance, not snapshot
        openedAt   = loan.openedAt;
        isActive   = loan.isActive;
    }

    /// @notice Full supply info for a lender.
    function supplyInfo(address user) external view returns (
        uint256 supplied,
        uint256 yield,
        uint256 total,
        uint256 depositedAt
    ) {
        Supply storage s = supplies[user];
        supplied    = s.amount;
        yield       = accruedYield(user); // accumulated + pending (FIX-2)
        total       = supplied + yield;
        depositedAt = s.depositedAt;
    }

    /// @notice Get the full collateral list length.
    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    /// @notice Get all collateral token addresses.
    function getAllCollaterals() external view returns (address[] memory) {
        return collateralList;
    }

    /// @notice Get a user's collateral balance for all registered tokens.
    function getAllCollateralBalances(address user)
        external view
        returns (address[] memory tokens, uint256[] memory balances)
    {
        uint256 len = collateralList.length;
        tokens    = new address[](len);
        balances  = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            tokens[i]   = collateralList[i];
            balances[i] = collateralBalances[user][collateralList[i]];
        }
    }
}
