//SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IBEP20Mintable is IBEP20 {
    function burn(uint256 amount) external;
    function mint(uint256 amount) external;
    function transferOwnership(address adr) external;
}

abstract contract Auth {
    address owner;
    mapping (address => bool) private authorizations;

    constructor(address _owner) {
        owner = _owner;
        authorizations[_owner] = true;
    }

    modifier onlyOwner() {
        require(isOwner(msg.sender)); _;
    }

    modifier authorized() {
        require(isAuthorized(msg.sender)); _;
    }

    function authorize(address adr) public onlyOwner {
        authorizations[adr] = true;
        emit Authorized(adr);
    }

    function unauthorize(address adr) public onlyOwner {
        authorizations[adr] = false;
        emit Unauthorized(adr);
    }
    function isOwner(address account) public view returns (bool) {
        return account == owner;
    }

    function isAuthorized(address adr) public view returns (bool) {
        return authorizations[adr];
    }

    function transferOwnership(address adr) public onlyOwner {
        owner = adr;
        authorizations[adr] = true;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
    event Authorized(address adr);
    event Unauthorized(address adr);
}

abstract contract Pausable is Auth {
    bool public paused;

    modifier whenPaused() {
        require(paused, "!PAUSED"); 
        _;
    }

    modifier notPaused() {
        require(!paused, "PAUSED"); 
        _;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() public onlyOwner {
        paused = false;
        emit Unpaused();
    }

    event Paused();
    event Unpaused();
}

interface IDataBridge {
    struct Request {
        uint256 srcChain;
        uint256 dstChain;
        address sender;
        address receiver;
        uint256 nonce;
        bytes method;
        bytes data;
    }
    
    enum RequestStatus {
        PENDING,
        SUCCESS,
        FAILED
    }
    
    function submitRequest(uint256 dstChain, address receiver, bytes32 method, bytes memory data) external returns (uint256 nonce);
    function fulfilRequest(Request memory req, bytes[] memory signatures) external;
    function cancelRequest(Request memory req, bytes[] memory signatures) external;
        
    event RequestSubmitted(Request);
    event RequestReceived(Request, RequestStatus);
    event RelayerUpdated(address relayer, bool state);
    event SignerUpdated(address signer, bool state);
    event SignatureThresholdUpdated(uint256 threshold);
    event SupportedChainUpdated(uint256 chain, bool state);
}

interface IDataReceiver {
    function bridgeCall(uint256 fromChain, address fromAddress, bytes32 method, bytes memory data) external;
}

contract TokenBridge is Auth, Pausable, IDataReceiver {
    IBEP20 token;
    IDataBridge bridge;
    
    bytes32 public TOKEN_TRANSFER = keccak256("transfer(address,uint256)");
    
    address public treasury;
    uint256 public treasuryFee;
    
    address public staking;
    uint256 public stakingFee;
    
    uint256 public minBridgeAmount;
    
    mapping (uint256 => address) public tokenBridges;
    
    constructor(IBEP20 _token, IDataBridge _bridge) Auth(msg.sender) {
        token = _token;
        bridge = _bridge;
    }
    
    function setTokenBridge(uint256 chain, address tokenBridge) external onlyOwner {
        tokenBridges[chain] = tokenBridge;
        emit TokenBridgeUpdated(chain, tokenBridge);
    }
    
    function setTreasuryFee(uint256 fee, address receiver) external onlyOwner {
        require(fee < 100, "Fee limit exceeded");
        treasuryFee = fee;
        treasury = receiver;
        emit TreasuryFeeUpdated(fee, receiver);
    }
    
    function setStakingFee(uint256 fee, address receiver) external onlyOwner {
        require(fee < 100, "Fee limit exceeded");
        stakingFee = fee;
        staking = receiver;
        emit StakingFeeUpdated(fee, receiver);
    }
    
    function setMinBridgeAmount(uint256 amount) external onlyOwner {
        minBridgeAmount = amount;
        emit MinBridgeAmountUpdated(amount);
    }
    
    function bridgeCall(uint256 fromChain, address fromAddress, bytes32 method, bytes memory data) external override notPaused {
        require(msg.sender == address(bridge), "!BRIDGE");
        require(tokenBridges[fromChain] == fromAddress, "!TOKEN_BRIDGE");
        require(method == TOKEN_TRANSFER);
        
        (address receiver, uint256 amount) = abi.decode(data, (address, uint256));
        token.transfer(receiver, takeFee(amount));
    }
    
    function bridgeTokens(uint256 dstChain, uint256 amount) external notPaused {
        address receiver = tokenBridges[dstChain];
        require(receiver != address(0), "Unsupported Chain");
        
        require(amount >= minBridgeAmount, "Insufficient Amount");
        
        token.transferFrom(msg.sender, address(this), amount);
        
        bridge.submitRequest(dstChain, receiver, TOKEN_TRANSFER, abi.encode(msg.sender, takeFee(amount)));
    }
    
    function takeFee(uint256 amount) internal returns (uint256) {
        uint256 feeToTreasury = treasuryFee * amount / 10000;
        if(feeToTreasury > 0)
            token.transfer(treasury, feeToTreasury);
            
        uint256 feeToStaking = stakingFee * amount / 10000;
        if(feeToStaking > 0)
            token.transfer(staking, feeToStaking);
        return amount - feeToTreasury - feeToStaking;
    }
    
    event TokenBridgeUpdated(uint256 chain, address tokenBridge);
    event TreasuryFeeUpdated(uint256 fee, address receiver);
    event StakingFeeUpdated(uint256 fee, address receiver);
    event MinBridgeAmountUpdated(uint256 amount);
}

contract MintableTokenBridge is Auth, Pausable, IDataReceiver {
    IBEP20Mintable token;
    IDataBridge bridge;
    
    bytes32 public TOKEN_TRANSFER = keccak256("transfer(address,uint256)");
    
    address public treasury;
    uint256 public treasuryFee;
    
    address public staking;
    uint256 public stakingFee;
    
    uint256 public minBridgeAmount;
    
    mapping (uint256 => address) public tokenBridges;
    
    constructor(IBEP20Mintable _token, IDataBridge _bridge) Auth(msg.sender) {
        token = _token;
        bridge = _bridge;
    }
    
    function setTokenBridge(uint256 chain, address tokenBridge) external onlyOwner {
        tokenBridges[chain] = tokenBridge;
        emit TokenBridgeUpdated(chain, tokenBridge);
    }
    
    function setTreasuryFee(uint256 fee, address receiver) external onlyOwner {
        require(fee < 100, "Fee limit exceeded");
        treasuryFee = fee;
        treasury = receiver;
        emit TreasuryFeeUpdated(fee, receiver);
    }
    
    function setStakingFee(uint256 fee, address receiver) external onlyOwner {
        require(fee < 100, "Fee limit exceeded");
        stakingFee = fee;
        staking = receiver;
        emit StakingFeeUpdated(fee, receiver);
    }
    
    function setMinBridgeAmount(uint256 amount) external onlyOwner {
        minBridgeAmount = amount;
        emit MinBridgeAmountUpdated(amount);
    }
    
    function bridgeCall(uint256 fromChain, address fromAddress, bytes32 method, bytes memory data) external override notPaused {
        require(msg.sender == address(bridge), "!BRIDGE");
        require(tokenBridges[fromChain] == fromAddress, "!TOKEN_BRIDGE");
        require(method == TOKEN_TRANSFER);
        
        (address receiver, uint256 amount) = abi.decode(data, (address, uint256));
        
        token.mint(amount);
        token.transfer(receiver, takeFee(amount));
    }
    
    function bridgeTokens(uint256 dstChain, uint256 amount) external notPaused {
        address receiver = tokenBridges[dstChain];
        require(receiver != address(0), "Unsupported Chain");
        
        require(amount >= minBridgeAmount, "Insufficient Amount");
        
        token.transferFrom(msg.sender, address(this), amount);
        uint256 amountAfterFee = takeFee(amount);
        token.burn(amountAfterFee);
        
        bridge.submitRequest(dstChain, receiver, TOKEN_TRANSFER, abi.encode(msg.sender, amountAfterFee));
    }
    
    function takeFee(uint256 amount) internal returns (uint256) {
        uint256 feeToTreasury = treasuryFee * amount / 10000;
        if(feeToTreasury > 0)
            token.transfer(treasury, feeToTreasury);
            
        uint256 feeToStaking = stakingFee * amount / 10000;
        if(feeToStaking > 0)
            token.transfer(staking, feeToStaking);
            
        return amount - feeToTreasury - feeToStaking;
    }
    
    function returnTokenOwnership() external onlyOwner {
        token.transferOwnership(msg.sender);
    }
    
    event TokenBridgeUpdated(uint256 chain, address tokenBridge);
    event TreasuryFeeUpdated(uint256 fee, address receiver);
    event StakingFeeUpdated(uint256 fee, address receiver);
    event MinBridgeAmountUpdated(uint256 amount);
}

