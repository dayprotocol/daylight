// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice One-shot CREATE proxy used by DayCreate3Factory.
/// @dev The factory creates and calls this proxy atomically. The target address depends on the
///      proxy address and nonce 1, not on the target constructor bytecode.
contract DayCreate3Proxy {
    address public immutable factory;
    address public deployed;

    error OnlyFactory();
    error AlreadyDeployed();
    error DeploymentFailed();

    constructor() {
        factory = msg.sender;
    }

    function deploy(bytes calldata creationCode) external returns (address target) {
        if (msg.sender != factory) revert OnlyFactory();
        if (deployed != address(0)) revert AlreadyDeployed();
        bytes memory code = creationCode;
        assembly {
            target := create(0, add(code, 0x20), mload(code))
        }
        if (target == address(0)) revert DeploymentFailed();
        deployed = target;
    }
}

/// @title DayCreate3Factory
/// @notice Adminless deterministic deployment factory for immutable DAY cross-chain transports.
/// @dev Salts are namespaced by caller, so another account cannot squat a deployer's route.
contract DayCreate3Factory {
    error EmptyCreationCode();
    error ProxyDeploymentFailed();
    error TargetAddressMismatch();
    error TargetAlreadyDeployed();

    event Deployed(address indexed deployer, bytes32 indexed salt, address indexed target);

    function deploy(bytes32 salt, bytes calldata creationCode) external returns (address target) {
        if (creationCode.length == 0) revert EmptyCreationCode();
        bytes32 namespacedSalt = _namespacedSalt(msg.sender, salt);
        address expected = predict(msg.sender, salt);
        if (expected.code.length != 0) revert TargetAlreadyDeployed();

        DayCreate3Proxy proxy;
        bytes memory proxyCode = type(DayCreate3Proxy).creationCode;
        assembly {
            proxy := create2(0, add(proxyCode, 0x20), mload(proxyCode), namespacedSalt)
        }
        if (address(proxy) == address(0)) revert ProxyDeploymentFailed();
        target = proxy.deploy(creationCode);
        if (target != expected) revert TargetAddressMismatch();
        emit Deployed(msg.sender, salt, target);
    }

    function predict(address deployer, bytes32 salt) public view returns (address target) {
        bytes32 proxyHash = keccak256(type(DayCreate3Proxy).creationCode);
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), _namespacedSalt(deployer, salt), proxyHash)
                    )
                )
            )
        );
        target = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    function _namespacedSalt(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }
}
