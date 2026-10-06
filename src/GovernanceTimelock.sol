// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Zero-value governance executor with immutable delay and independently cancellable proposals.
/// @dev Production proposer and canceller should be distinct reviewed multisigs, not worker keys.
contract GovernanceTimelock {
    address public immutable proposer;
    address public immutable canceller;
    uint256 public immutable delay;
    uint256 public constant GRACE_PERIOD = 7 days;
    mapping(bytes32 => uint256) public readyAt;
    mapping(bytes32 => bool) public done;
    bool private executing;

    error Unauthorized();
    error InvalidOperation();
    error NotReady();
    error ExecutionFailed(bytes reason);
    event Scheduled(bytes32 indexed id, address indexed target, bytes data, bytes32 salt, uint256 readyAt);
    event Cancelled(bytes32 indexed id);
    event Executed(bytes32 indexed id);

    constructor(address proposer_, address canceller_, uint256 delay_) {
        if (
            proposer_ == address(0) || canceller_ == address(0) || proposer_ == canceller_ || delay_ < 2 days
                || delay_ > 30 days
        ) revert InvalidOperation();
        proposer = proposer_;
        canceller = canceller_;
        delay = delay_;
    }

    function hashOperation(address target, bytes calldata data, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), target, keccak256(data), salt));
    }

    function schedule(address target, bytes calldata data, bytes32 salt) external returns (bytes32 id) {
        if (msg.sender != proposer) revert Unauthorized();
        id = hashOperation(target, data, salt);
        if (target.code.length == 0 || data.length < 4 || readyAt[id] != 0 || done[id]) {
            revert InvalidOperation();
        }
        uint256 when = block.timestamp + delay;
        readyAt[id] = when;
        emit Scheduled(id, target, data, salt, when);
    }

    function cancel(bytes32 id) external {
        if (msg.sender != proposer && msg.sender != canceller) revert Unauthorized();
        if (readyAt[id] == 0 || done[id]) revert InvalidOperation();
        delete readyAt[id];
        emit Cancelled(id);
    }

    function execute(address target, bytes calldata data, bytes32 salt)
        external
        returns (bytes memory result)
    {
        bytes32 id = hashOperation(target, data, salt);
        uint256 when = readyAt[id];
        if (
            executing || done[id] || when == 0 || block.timestamp < when
                || block.timestamp > when + GRACE_PERIOD
        ) {
            revert NotReady();
        }
        executing = true;
        done[id] = true;
        delete readyAt[id];
        (bool ok, bytes memory returned) = target.call(data);
        if (!ok) revert ExecutionFailed(returned);
        executing = false;
        emit Executed(id);
        return returned;
    }
}
