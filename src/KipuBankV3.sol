// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "@uniswap/v4-core/contracts/interfaces/IUniversalRouter.sol";
import "@uniswap/v4-core/contracts/interfaces/IPermit2.sol";

import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/contracts/libraries/Commands.sol";
import "@uniswap/v4-periphery/src/libraries/Actions.sol";

// ========== WETH Helper ==========
interface WETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolKey for PoolKey.PoolKey;
    using Currency for Currency.Currency;
    using Commands for Commands.Command[];
    using Actions for Actions.Action[];

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // USDC Configuration (6 decimals)
    uint8 private constant USDC_DECIMALS = 6;
    uint256 private constant DECIMALS_MULTIPLIER = 10**USDC_DECIMALS;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Mainnet USDC

    // Bank configuration
    uint256 public immutable bankCap; // Global deposit limit in USDC (6 decimals)
    uint256 public totalDeposits; // Total deposits in USDC (6 decimals)

    // Chainlink ETH/USD Price Feed
    AggregatorV3Interface internal ethUsdPriceFeed;

    // Uniswap V4
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;

    // User accounts
    struct UserBalance {
        uint256 amount; // In USDC (6 decimals)
        uint256 lastDepositTimestamp;
    }

    struct Account {
        UserBalance balance;
        bool exists;
        uint256 depositCount;
        uint256 withdrawalCount;
    }

    mapping(address => Account) public accounts;

    // Configuration parameters
    uint256 public minimumDeposit = 100 * 10**USDC_DECIMALS; // 100 USDC
    uint256 public withdrawalFee = 5; // 5% fee
    uint256 public lockPeriod = 1 days;
    uint256 private constant MAX_WITHDRAWAL_PER_TRANSACTION = 200 * 10**USDC_DECIMALS;

    // Counters
    uint256 public totalDepositsCount;
    uint256 public totalWithdrawalsCount;

    // Errors
    error KipuBank__AccountAlreadyExists();
    error KipuBank__AccountDoesNotExist();
    error KipuBank__InsufficientBalance();
    error KipuBank__AmountBelowMinimumDeposit();
    error KipuBank__DepositExceedsBankCapacity();
    error KipuBank__FundsLocked(uint256 unlockTime);
    error KipuBank__WithdrawalLimitExceeded();
    error KipuBank__TokenNotSupported();
    error KipuBank__InvalidPrice();
    error KipuBank__ZeroAddress();
    error KipuBank__Unauthorized();
    error KipuBank__TransferFailed();
    error KipuBank__SwapFailed();
    error KipuBank__NoSwapNeeded();

    // Events
    event AccountCreated(address indexed owner);
    event Deposited(
        address indexed owner,
        address indexed token,
        uint256 amount,
        uint256 usdcAmount,
        uint256 userDepositCount,
        uint256 totalDepositsCount
    );
    event Withdrawn(
        address indexed owner,
        uint256 amount,
        uint256 fee,
        uint256 userWithdrawalCount,
        uint256 totalWithdrawalsCount
    );
    event MinimumDepositUpdated(uint256 newMinimumDeposit);
    event WithdrawalFeeUpdated(uint256 newWithdrawalFee);
    event LockPeriodUpdated(uint256 newLockPeriod);
    event BankCapSet(uint256 cap);
    event PriceFeedUpdated(address newPriceFeed);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event EmergencyWithdrawal(address indexed owner, uint256 amount);
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(
        uint256 _bankCap,
        address _priceFeedAddress,
        address _universalRouterAddress,
        address _permit2Address
    ) {
        require(_priceFeedAddress != address(0), "Price feed cannot be zero");
        require(_universalRouterAddress != address(0), "UniversalRouter cannot be zero");
        require(_permit2Address != address(0), "Permit2 cannot be zero");

        // Setup roles
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        bankCap = _bankCap;
        ethUsdPriceFeed = AggregatorV3Interface(_priceFeedAddress);
        universalRouter = IUniversalRouter(_universalRouterAddress);
        permit2 = IPermit2(_permit2Address);

        emit BankCapSet(_bankCap);
        emit PriceFeedUpdated(_priceFeedAddress);
        emit RoleGranted(ADMIN_ROLE, msg.sender);
        emit RoleGranted(OPERATOR_ROLE, msg.sender);
    }

    // ========== Access Control ==========
    function grantRole(bytes32 role, address account) public override onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
        emit RoleGranted(role, account);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(ADMIN_ROLE) {
        _revokeRole(role, account);
        emit RoleRevoked(role, account);
    }

    // ========== Account Management ==========
    function createAccount() external {
        if (accounts[msg.sender].exists) {
            revert KipuBank__AccountAlreadyExists();
        }

        accounts[msg.sender] = Account({
            balance: UserBalance({amount: 0, lastDepositTimestamp: 0}),
            exists: true,
            depositCount: 0,
            withdrawalCount: 0
        });

        emit AccountCreated(msg.sender);
    }

    // ========== Core Banking Functions ==========
    function deposit(address tokenAddress, uint256 amount) public payable nonReentrant {
        if (!accounts[msg.sender].exists) {
            revert KipuBank__AccountDoesNotExist();
        }

        // Check minimum deposit
        if (amount < minimumDeposit) {
            revert KipuBank__AmountBelowMinimumDeposit();
        }

        uint256 usdcAmount;

        if (tokenAddress == address(0)) {
            // ETH deposit - swap to USDC
            usdcAmount = _swapExactInputSingle(address(WETH9), amount, msg.sender);
        } else if (tokenAddress == USDC) {
            // USDC deposit - no swap needed
            usdcAmount = amount;

            // Transfer USDC directly
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            // ERC20 token - swap to USDC
            usdcAmount = _swapExactInputSingle(tokenAddress, amount, msg.sender);
        }

        // Check bank capacity
        if (totalDeposits + usdcAmount > bankCap) {
            revert KipuBank__DepositExceedsBankCapacity();
        }

        // Update balances
        accounts[msg.sender].balance.amount += usdcAmount;
        accounts[msg.sender].balance.lastDepositTimestamp = block.timestamp;
        accounts[msg.sender].depositCount++;
        totalDeposits += usdcAmount;
        totalDepositsCount++;

        emit Deposited(msg.sender, tokenAddress, amount, usdcAmount, accounts[msg.sender].depositCount, totalDepositsCount);
    }

    function depositArbitraryToken(address tokenAddress, uint256 amount) external nonReentrant {
        deposit(tokenAddress, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        Account storage account = accounts[msg.sender];

        if (!account.exists) {
            revert KipuBank__AccountDoesNotExist();
        }

        if (account.balance.amount < amount) {
            revert KipuBank__InsufficientBalance();
        }

        // Check lock period
        if (block.timestamp < account.balance.lastDepositTimestamp + lockPeriod) {
            revert KipuBank__FundsLocked(account.balance.lastDepositTimestamp + lockPeriod);
        }

        // Check withdrawal limit
        if (amount > MAX_WITHDRAWAL_PER_TRANSACTION) {
            revert KipuBank__WithdrawalLimitExceeded();
        }

        // Calculate fee
        uint256 feeAmount = (amount * withdrawalFee) / 100;
        uint256 amountAfterFee = amount - feeAmount;

        // Update balances
        account.balance.amount -= amount;
        account.withdrawalCount++;
        totalDeposits -= amount;
        totalWithdrawalsCount++;

        // Transfer USDC
        IERC20(USDC).safeTransfer(msg.sender, amountAfterFee);

        emit Withdrawn(msg.sender, amount, feeAmount, account.withdrawalCount, totalWithdrawalsCount);
    }

    // Emergency withdrawal (no fees, no lock period)
    function emergencyWithdraw() external nonReentrant {
        if (!hasRole(EMERGENCY_ROLE, msg.sender) && !accounts[msg.sender].exists) {
            revert KipuBank__AccountDoesNotExist();
        }

        Account storage account = accounts[msg.sender];
        uint256 amount = account.balance.amount;

        if (amount == 0) {
            return;
        }

        // Update balances
        account.balance.amount = 0;
        account.withdrawalCount++;
        totalDeposits -= amount;

        // Transfer USDC
        IERC20(USDC).safeTransfer(msg.sender, amount);

        emit EmergencyWithdrawal(msg.sender, amount);
    }

    // ========== View Functions ==========
    function getUserBalance(address user) external view returns (uint256) {
        if (!accounts[user].exists) {
            revert KipuBank__AccountDoesNotExist();
        }
        return accounts[user].balance.amount;
    }

    function getTotalDepositsInUsd() external view returns (uint256) {
        return totalDeposits;
    }

    function getUserDepositCount(address user) external view returns (uint256) {
        if (!accounts[user].exists) {
            revert KipuBank__AccountDoesNotExist();
        }
        return accounts[user].depositCount;
    }

    function getUserWithdrawalCount(address user) external view returns (uint256) {
        if (!accounts[user].exists) {
            revert KipuBank__AccountDoesNotExist();
        }
        return accounts[user].withdrawalCount;
    }

    function getLatestEthPrice() public view returns (uint256) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        if (price <= 0) {
            revert KipuBank__InvalidPrice();
        }
        return uint256(price);
    }

    // ========== Admin Functions ==========
    function setMinimumDeposit(uint256 _minimumDeposit) external onlyRole(ADMIN_ROLE) {
        minimumDeposit = _minimumDeposit;
        emit MinimumDepositUpdated(_minimumDeposit);
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external onlyRole(ADMIN_ROLE) {
        require(_withdrawalFee <= 10, "Fee cannot exceed 10%");
        withdrawalFee = _withdrawalFee;
        emit WithdrawalFeeUpdated(_withdrawalFee);
    }

    function setLockPeriod(uint256 _lockPeriod) external onlyRole(ADMIN_ROLE) {
        lockPeriod = _lockPeriod;
        emit LockPeriodUpdated(_lockPeriod);
    }

    function setPriceFeed(address _priceFeedAddress) external onlyRole(ADMIN_ROLE) {
        if (_priceFeedAddress == address(0)) {
            revert KipuBank__ZeroAddress();
        }
        ethUsdPriceFeed = AggregatorV3Interface(_priceFeedAddress);
        emit PriceFeedUpdated(_priceFeedAddress);
    }

    function withdrawFees() external nonReentrant onlyRole(ADMIN_ROLE) {
        uint256 contractBalance = IERC20(USDC).balanceOf(address(this));
        uint256 totalUserBalances = totalDeposits;

        uint256 fees = contractBalance > totalUserBalances ? contractBalance - totalUserBalances : 0;
        if (fees == 0) {
            return;
        }

        IERC20(USDC).safeTransfer(msg.sender, fees);
    }

    // ========== Internal Swap Functions ==========
    function _swapExactInputSingle(
        address tokenIn,
        uint256 amountIn,
        address payer
    ) internal returns (uint256 amountOut) {
        if (tokenIn == USDC) {
            revert KipuBank__NoSwapNeeded();
        }

        // Wrap ETH if needed
        if (tokenIn == address(0)) {
            WETH9.deposit{value: amountIn}();
            tokenIn = address(WETH9);
        } else {
            // Transfer tokens from user to this contract
            IERC20(tokenIn).safeTransferFrom(payer, address(this), amountIn);
        }

        // Approve Universal Router to spend tokens
        IERC20(tokenIn).safeApprove(address(universalRouter), amountIn);

        // Prepare swap command
        Currency.Currency currencyIn = Currency.Currency.wrap(tokenIn);
        Currency.Currency currencyOut = Currency.Currency.wrap(USDC);

        // Get pool key
        PoolKey.PoolKey memory poolKey = PoolKey.getPoolKey(currencyIn, currencyOut, 0.0005e18);

        // Create commands for the swap
        Commands.Command[] memory commands = new Commands.Command[](1);
        commands[0] = Commands.Command(
            Actions.Action.Swap,
            Actions.SwapParams({
                recipient: address(this),
                zeroForOne: currencyIn < currencyOut,
                amountSpecified: int256(amountIn),
                limitSqrtPrice: 0
            })
        );

        // Execute swap
        IUniversalRouter.ExecutionDetails memory details = universalRouter.execute(
            commands,
            PoolKey.encode(poolKey),
            payer,
            block.timestamp + 300
        );

        if (details.amountOut < 0) {
            revert KipuBank__SwapFailed();
        }

        amountOut = uint256(details.amountOut);

        emit SwapExecuted(tokenIn, USDC, amountIn, amountOut);
        return amountOut;
    }

    // ========== Fallback for ETH deposits ==========
    receive() external payable {
        deposit(address(0), msg.value);
    }    
}
