// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IERC20DayPosition {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC4626DayPosition {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

interface IAaveV3PoolDayPosition {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

interface IAaveScaledTokenDayPosition {
    function scaledBalanceOf(address user) external view returns (uint256);
}

interface ICompoundV3DayPosition {
    function balanceOf(address owner) external view returns (uint256);
    function withdrawTo(address to, address asset, uint256 amount) external;
    function accrueAccount(address account) external;
    function baseIndexScale() external view returns (uint64);
    function totalsBasic()
        external
        view
        returns (
            uint64 baseSupplyIndex,
            uint64 baseBorrowIndex,
            uint64 trackingSupplyIndex,
            uint64 trackingBorrowIndex,
            uint104 totalSupplyBase,
            uint104 totalBorrowBase,
            uint40 lastAccrualTime,
            uint8 pauseFlags
        );
    function userBasic(address account)
        external
        view
        returns (int104 principal, uint64 baseTrackingIndex, uint64 baseTrackingAccrued, uint16 assetsIn);
}

interface IMoonwellMTokenDayPosition {
    function balanceOf(address account) external view returns (uint256);
    function redeem(uint256 mTokenAmount) external returns (uint256 errorCode);
}

/// @title DayOriginBoundPosition
/// @notice Immutable, non-upgradeable receipt owner for one cross-chain DAY position.
/// @dev This contract deliberately has no admin, owner setter, rescue, arbitrary call, delegatecall,
///      arbitrary receiver, or upgrade surface. The sole command authority is the immutable DAY
///      destination router, whose withdrawal entry point must authenticate the recorded origin owner.
///      Until that router is backed by the production LayerZero rail tracked in DAY-876, routes using
///      this primitive MUST remain non-executable in public readiness.
contract DayOriginBoundPosition {
    uint8 public constant KIND_AAVE_V3 = 1;
    uint8 public constant KIND_ERC4626 = 2;
    uint8 public constant KIND_COMPOUND_V3 = 3;
    uint8 public constant KIND_COMPOUND_V2_MTOKEN = 4;
    uint256 private constant RAY = 1e27;
    uint256 private constant HALF_RAY = 5e26;

    address public immutable authenticatedRouter;
    bytes32 public immutable dayTxId;
    address public immutable controller;
    bytes32 public immutable originOwner;
    bytes32 public immutable sourceRouteHash;
    bytes32 public immutable destinationRouteHash;
    bytes32 public immutable opportunityId;
    bytes32 public immutable adapterId;
    address public immutable asset;
    address public immutable receiptToken;
    address public immutable venue;
    uint8 public immutable positionKind;
    bytes32 public immutable bindingHash;

    bool private _locked;

    error OnlyAuthenticatedRouter();
    error ZeroAddress();
    error AddressHasNoCode();
    error InvalidBinding();
    error InvalidAmount();
    error PositionAmountExceeded();
    error BalanceDeltaMismatch();
    error ProtocolError(uint256 errorCode);
    error TransferFailed();
    error Reentrancy();

    event PositionExited(
        bytes32 indexed dayTxId,
        bytes32 indexed opportunityId,
        bytes32 indexed originOwner,
        uint256 positionAmount,
        uint256 outputAmount
    );

    struct Binding {
        address authenticatedRouter;
        bytes32 dayTxId;
        address controller;
        bytes32 originOwner;
        bytes32 sourceRouteHash;
        bytes32 destinationRouteHash;
        bytes32 opportunityId;
        bytes32 adapterId;
        address asset;
        address receiptToken;
        address venue;
        uint8 positionKind;
    }

    constructor(Binding memory binding) {
        if (
            binding.authenticatedRouter == address(0) || binding.controller == address(0) || binding.asset == address(0)
                || binding.receiptToken == address(0) || binding.venue == address(0)
        ) revert ZeroAddress();
        if (
            binding.dayTxId == bytes32(0) || binding.originOwner == bytes32(0) || binding.sourceRouteHash == bytes32(0)
                || binding.destinationRouteHash == bytes32(0) || binding.opportunityId == bytes32(0)
                || binding.adapterId == bytes32(0)
                || (binding.positionKind != KIND_AAVE_V3
                    && binding.positionKind != KIND_ERC4626
                    && binding.positionKind != KIND_COMPOUND_V3
                    && binding.positionKind != KIND_COMPOUND_V2_MTOKEN)
        ) revert InvalidBinding();
        if (
            binding.authenticatedRouter.code.length == 0 || binding.asset.code.length == 0
                || binding.receiptToken.code.length == 0 || binding.venue.code.length == 0
        ) revert AddressHasNoCode();

        authenticatedRouter = binding.authenticatedRouter;
        dayTxId = binding.dayTxId;
        controller = binding.controller;
        originOwner = binding.originOwner;
        sourceRouteHash = binding.sourceRouteHash;
        destinationRouteHash = binding.destinationRouteHash;
        opportunityId = binding.opportunityId;
        adapterId = binding.adapterId;
        asset = binding.asset;
        receiptToken = binding.receiptToken;
        venue = binding.venue;
        positionKind = binding.positionKind;
        bindingHash = keccak256(abi.encode(binding));
    }

    /// @notice Current venue position units. Aave positions use scaled aToken units; ERC-4626
    ///         positions use exact vault shares; Compound V3 uses stable positive principal;
    ///         Compound-v2 markets use exact mToken units.
    function positionBalance() public view returns (uint256) {
        if (positionKind == KIND_AAVE_V3) {
            return IAaveScaledTokenDayPosition(receiptToken).scaledBalanceOf(address(this));
        }
        if (positionKind == KIND_COMPOUND_V3) {
            (int104 principal,,,) = ICompoundV3DayPosition(receiptToken).userBasic(address(this));
            return principal > 0 ? uint104(principal) : 0;
        }
        return IERC4626DayPosition(receiptToken).balanceOf(address(this));
    }

    /// @notice Exit venue shares to the immutable authenticated router. There is intentionally no
    ///         receiver parameter: the caller cannot substitute a payout destination.
    function exit(uint256 positionAmount) external returns (uint256 outputAmount) {
        if (msg.sender != authenticatedRouter) revert OnlyAuthenticatedRouter();
        if (_locked) revert Reentrancy();
        if (positionAmount == 0) revert InvalidAmount();
        uint256 beforePosition = positionBalance();
        if (positionAmount > beforePosition) revert PositionAmountExceeded();

        _locked = true;
        uint256 beforeAsset = _balanceOf(asset, authenticatedRouter);
        if (positionKind == KIND_AAVE_V3) {
            uint256 index = IAaveV3PoolDayPosition(venue).getReserveNormalizedIncome(asset);
            uint256 requestedUnderlying = _rayMul(positionAmount, index);
            uint256 totalUnderlying = _balanceOf(receiptToken, address(this));
            if (requestedUnderlying > totalUnderlying) requestedUnderlying = totalUnderlying;
            outputAmount = IAaveV3PoolDayPosition(venue).withdraw(asset, requestedUnderlying, authenticatedRouter);
        } else if (positionKind == KIND_ERC4626) {
            outputAmount = IERC4626DayPosition(venue).redeem(positionAmount, authenticatedRouter, address(this));
        } else if (positionKind == KIND_COMPOUND_V3) {
            // Accrue first so the index cannot advance between the view and withdraw.
            // Comet stores principal but withdraws present-value asset units. Select the
            // remaining present value with ceiling division so Comet's floor conversion
            // lands on exactly `beforePosition - positionAmount` principal units.
            ICompoundV3DayPosition(venue).accrueAccount(address(this));
            (uint64 supplyIndex,,,,,,,) = ICompoundV3DayPosition(venue).totalsBasic();
            uint64 indexScale = ICompoundV3DayPosition(venue).baseIndexScale();
            if (indexScale == 0 || supplyIndex < indexScale) revert InvalidAmount();
            uint256 remainingPrincipal = beforePosition - positionAmount;
            uint256 remainingPresent = _mulDivUp(remainingPrincipal, supplyIndex, indexScale);
            uint256 accruedBalance = ICompoundV3DayPosition(venue).balanceOf(address(this));
            if (accruedBalance <= remainingPresent) revert InvalidAmount();
            uint256 withdrawAmount = accruedBalance - remainingPresent;
            ICompoundV3DayPosition(venue).withdrawTo(authenticatedRouter, asset, withdrawAmount);
            outputAmount = _balanceOf(asset, authenticatedRouter) - beforeAsset;
        } else {
            uint256 beforeLocalAsset = _balanceOf(asset, address(this));
            uint256 errorCode = IMoonwellMTokenDayPosition(venue).redeem(positionAmount);
            if (errorCode != 0) revert ProtocolError(errorCode);
            outputAmount = _balanceOf(asset, address(this)) - beforeLocalAsset;
            if (outputAmount == 0) revert BalanceDeltaMismatch();
            _safeTransfer(asset, authenticatedRouter, outputAmount);
        }
        _locked = false;

        uint256 received = _balanceOf(asset, authenticatedRouter) - beforeAsset;
        uint256 burned = beforePosition - positionBalance();
        if (outputAmount == 0 || outputAmount != received || burned != positionAmount) {
            revert BalanceDeltaMismatch();
        }
        emit PositionExited(dayTxId, opportunityId, originOwner, positionAmount, outputAmount);
    }

    function _rayMul(uint256 value, uint256 ray) internal pure returns (uint256) {
        if (value == 0 || ray == 0) return 0;
        if (value > (type(uint256).max - HALF_RAY) / ray) revert InvalidAmount();
        return (value * ray + HALF_RAY) / RAY;
    }

    function _mulDivUp(uint256 value, uint256 multiplier, uint256 divisor) internal pure returns (uint256) {
        if (divisor == 0 || (value != 0 && multiplier > type(uint256).max / value)) revert InvalidAmount();
        uint256 product = value * multiplier;
        if (product == 0) return 0;
        return (product - 1) / divisor + 1;
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory result) = token.staticcall(abi.encodeCall(IERC20DayPosition.balanceOf, (account)));
        if (!ok || result.length < 32) revert TransferFailed();
        return abi.decode(result, (uint256));
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20DayPosition.transfer, (to, amount)));
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }
}

/// @notice Stateless CREATE2 deployer kept outside the router so position creation bytecode does
///         not push the execution router over EIP-170. It has no owner or mutable configuration.
contract DayOriginBoundPositionFactory {
    error CallerNotAuthenticatedRouter();

    event PositionDeployed(bytes32 indexed dayTxId, address indexed authenticatedRouter, address position);

    function deploy(bytes32 salt, DayOriginBoundPosition.Binding calldata binding)
        external
        returns (DayOriginBoundPosition position)
    {
        if (binding.authenticatedRouter != msg.sender) revert CallerNotAuthenticatedRouter();
        position = new DayOriginBoundPosition{salt: salt}(binding);
        emit PositionDeployed(binding.dayTxId, msg.sender, address(position));
    }

    function predict(bytes32 salt, DayOriginBoundPosition.Binding calldata binding) external view returns (address) {
        bytes memory initCode = abi.encodePacked(type(DayOriginBoundPosition).creationCode, abi.encode(binding));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode)))))
            );
    }
}
