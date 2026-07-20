// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IERC20DaySwapAdapter {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ISwapRouter02DayAdapter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

interface IDaySwapAdapter {
    function executor() external view returns (address);
    function bridgeToken() external view returns (address);
    function wrappedNative() external view returns (address);
    function supportsToken(address token) external view returns (bool);

    function swapToBridge(
        bytes32 dayTxId,
        address tokenIn,
        uint256 maxAmountIn,
        uint256 exactBridgeAmountOut,
        uint64 deadline
    ) external returns (uint256 amountIn);

    function swapFromBridge(
        bytes32 dayTxId,
        address tokenOut,
        uint256 bridgeAmountIn,
        uint256 minAmountOut,
        uint64 deadline
    ) external returns (uint256 amountOut);
}

/// @notice Immutable Uniswap V3 swap boundary for DAY's EVM bridge asset.
/// @dev Supports only the canonical USDT and wrapped-native pairs on Base/Arbitrum.
///      Router, tokens and fee tiers are hard-pinned. There is no owner, rescue,
///      arbitrary calldata, mutable allowlist or retained-balance payout path.
contract DayUniswapV3SwapAdapter is IDaySwapAdapter {
    address private constant BASE_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    address private constant ARBITRUM_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address private constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant ARBITRUM_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint24 private constant STABLE_FEE = 100;
    uint24 private constant WETH_FEE = 500;

    address public immutable executor;
    address public immutable router;
    address public immutable bridgeToken;
    address public immutable supportedUsdt;
    address public immutable wrappedNative;

    error OnlyExecutor();
    error ZeroAddress();
    error AddressHasNoCode();
    error UnsupportedChain();
    error UnsupportedToken();
    error InvalidAmount();
    error DeadlineExpired();
    error BalanceDeltaMismatch();
    error TransferFailed();

    event SourceAssetSwapped(
        bytes32 indexed dayTxId,
        address indexed tokenIn,
        address indexed bridgeToken,
        uint256 amountIn,
        uint256 bridgeAmountOut
    );
    event ReturnAssetSwapped(
        bytes32 indexed dayTxId,
        address indexed bridgeToken,
        address indexed tokenOut,
        uint256 bridgeAmountIn,
        uint256 amountOut
    );

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    constructor(address executor_) {
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        if (block.chainid == 8453) {
            router = BASE_ROUTER;
            bridgeToken = BASE_USDC;
            supportedUsdt = BASE_USDT;
            wrappedNative = BASE_WETH;
        } else if (block.chainid == 42161) {
            router = ARBITRUM_ROUTER;
            bridgeToken = ARBITRUM_USDC;
            supportedUsdt = ARBITRUM_USDT;
            wrappedNative = ARBITRUM_WETH;
        } else {
            revert UnsupportedChain();
        }
        if (
            router.code.length == 0 || bridgeToken.code.length == 0 || supportedUsdt.code.length == 0
                || wrappedNative.code.length == 0
        ) revert AddressHasNoCode();
    }

    function supportsToken(address token) public view returns (bool) {
        return token == supportedUsdt || token == wrappedNative;
    }

    function swapToBridge(
        bytes32 dayTxId,
        address tokenIn,
        uint256 maxAmountIn,
        uint256 exactBridgeAmountOut,
        uint64 deadline
    ) external onlyExecutor returns (uint256 amountIn) {
        _validate(dayTxId, tokenIn, maxAmountIn, exactBridgeAmountOut, deadline);
        uint256 beforeInput = _balanceOf(tokenIn, address(this));
        uint256 beforeBridge = _balanceOf(bridgeToken, address(this));
        _safeTransferFrom(tokenIn, msg.sender, address(this), maxAmountIn);
        if (_balanceOf(tokenIn, address(this)) - beforeInput != maxAmountIn) revert BalanceDeltaMismatch();

        _approveExact(tokenIn, router, maxAmountIn);
        amountIn = ISwapRouter02DayAdapter(router)
            .exactOutputSingle(
                ISwapRouter02DayAdapter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: bridgeToken,
                fee: _fee(tokenIn),
                recipient: address(this),
                amountOut: exactBridgeAmountOut,
                amountInMaximum: maxAmountIn,
                sqrtPriceLimitX96: 0
            })
            );
        _approveExact(tokenIn, router, 0);

        uint256 remainingInput = _balanceOf(tokenIn, address(this)) - beforeInput;
        uint256 bridgeReceived = _balanceOf(bridgeToken, address(this)) - beforeBridge;
        if (amountIn == 0 || amountIn + remainingInput != maxAmountIn || bridgeReceived != exactBridgeAmountOut) {
            revert BalanceDeltaMismatch();
        }
        if (remainingInput != 0) _safeTransfer(tokenIn, msg.sender, remainingInput);
        _safeTransfer(bridgeToken, msg.sender, bridgeReceived);
        if (_balanceOf(tokenIn, address(this)) != beforeInput || _balanceOf(bridgeToken, address(this)) != beforeBridge)
        {
            revert BalanceDeltaMismatch();
        }
        emit SourceAssetSwapped(dayTxId, tokenIn, bridgeToken, amountIn, bridgeReceived);
    }

    function swapFromBridge(
        bytes32 dayTxId,
        address tokenOut,
        uint256 bridgeAmountIn,
        uint256 minAmountOut,
        uint64 deadline
    ) external onlyExecutor returns (uint256 amountOut) {
        _validate(dayTxId, tokenOut, bridgeAmountIn, minAmountOut, deadline);
        uint256 beforeBridge = _balanceOf(bridgeToken, address(this));
        uint256 beforeOutput = _balanceOf(tokenOut, address(this));
        _safeTransferFrom(bridgeToken, msg.sender, address(this), bridgeAmountIn);
        if (_balanceOf(bridgeToken, address(this)) - beforeBridge != bridgeAmountIn) {
            revert BalanceDeltaMismatch();
        }

        _approveExact(bridgeToken, router, bridgeAmountIn);
        amountOut = ISwapRouter02DayAdapter(router)
            .exactInputSingle(
                ISwapRouter02DayAdapter.ExactInputSingleParams({
                tokenIn: bridgeToken,
                tokenOut: tokenOut,
                fee: _fee(tokenOut),
                recipient: address(this),
                amountIn: bridgeAmountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
            );
        _approveExact(bridgeToken, router, 0);

        uint256 outputReceived = _balanceOf(tokenOut, address(this)) - beforeOutput;
        if (
            amountOut < minAmountOut || amountOut != outputReceived
                || _balanceOf(bridgeToken, address(this)) != beforeBridge
        ) revert BalanceDeltaMismatch();
        _safeTransfer(tokenOut, msg.sender, outputReceived);
        if (_balanceOf(tokenOut, address(this)) != beforeOutput) revert BalanceDeltaMismatch();
        emit ReturnAssetSwapped(dayTxId, bridgeToken, tokenOut, bridgeAmountIn, outputReceived);
    }

    function _validate(bytes32 dayTxId, address token, uint256 amountA, uint256 amountB, uint64 deadline)
        internal
        view
    {
        if (dayTxId == bytes32(0) || amountA == 0 || amountB == 0) revert InvalidAmount();
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (!supportsToken(token)) revert UnsupportedToken();
    }

    function _fee(address token) internal view returns (uint24) {
        if (token == supportedUsdt) return STABLE_FEE;
        if (token == wrappedNative) return WETH_FEE;
        revert UnsupportedToken();
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory result) = token.staticcall(abi.encodeCall(IERC20DaySwapAdapter.balanceOf, (account)));
        if (!ok || result.length < 32) revert TransferFailed();
        return abi.decode(result, (uint256));
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20DaySwapAdapter.transfer, (to, amount)));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20DaySwapAdapter.transferFrom, (from, to, amount)));
    }

    function _approveExact(address token, address spender, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20DaySwapAdapter.approve, (spender, 0)));
        if (amount != 0) _callOptionalReturn(token, abi.encodeCall(IERC20DaySwapAdapter.approve, (spender, amount)));
    }

    function _callOptionalReturn(address token, bytes memory data) internal {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }
}
