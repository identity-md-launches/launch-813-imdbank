// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockToken {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps;
    uint8 public returnMode;
    address public callback;
    bytes public callbackData;
    bool private inCallback;

    constructor(uint8 d) {
        decimals = d;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setReturnMode(uint8 mode) external {
        returnMode = mode;
    }

    function setCallback(address target, bytes memory data) external {
        callback = target;
        callbackData = data;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return _return();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return _return();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return _return();
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        if (callback != address(0) && !inCallback) {
            inCallback = true;
            (bool ok,) = callback.call(callbackData);
            require(ok, "callback rejected");
            inCallback = false;
        }
    }

    function _return() private view returns (bool) {
        if (returnMode == 1) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return returnMode != 2;
    }
}

contract MockFeed {
    uint8 public decimals = 8;
    int256 public answer = 1e8;
    uint80 public round = 1;
    uint80 public answered = 1;
    uint256 public updated;
    bool public live = true;

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setRound(uint80 r, uint80 ar, uint256 timestamp) external {
        round = r;
        answered = ar;
        updated = timestamp;
        live = false;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 t = live ? block.timestamp : updated;
        return (round, answer, t, t, answered);
    }
}

contract MockOracle {
    mapping(address => uint256) public prices;
    bool public broken;

    function setPrice(address asset, uint256 amount) external {
        prices[asset] = amount;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function price(address asset) external view returns (uint256) {
        require(!broken && prices[asset] > 0, "oracle unavailable");
        return prices[asset];
    }
}
