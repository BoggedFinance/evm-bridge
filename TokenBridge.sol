//SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20Mintable is IERC20 {
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

interface IPricingManager {
    function getBOGAmountForUSD(uint256 amountUSD, uint256 denominator) external view returns (uint256);
    function getNativeAmountForUSD(uint256 amountUSD, uint256 denominator) external view returns (uint256);
}

abstract contract PricingManaged is Auth, IPricingManager {
    IPricingManager public pricingManager;
    
    constructor (IPricingManager _pricingManager) {
        pricingManager = _pricingManager;
    }
    
    function getBOGAmountForUSD(uint256 amountUSD, uint256 denominator) public view override returns (uint256) {
        return pricingManager.getBOGAmountForUSD(amountUSD, denominator);
    }
    
    function getNativeAmountForUSD(uint256 amountUSD, uint256 denominator) public view override returns (uint256) {
        return pricingManager.getNativeAmountForUSD(amountUSD, denominator);
    }
    
    function migratePricingManager(IPricingManager _pricingManager) external onlyOwner {
        pricingManager = _pricingManager;
    }
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
    event RelayerUpdated(address indexed relayer, bool state);
    event SignerUpdated(address indexed signer, bool state);
    event SignatureThresholdUpdated(uint256 threshold);
    event SupportedChainUpdated(uint256 chain, bool state);
}

interface IDataReceiver {
    function bridgeCall(uint256 fromChain, address fromAddress, bytes32 method, bytes memory data) external;
}

interface ITokenBridge {
    function bridge(uint256 dstChain, uint256 amountIn, bytes memory data) external;
}

interface ITokenBridgeRouter {
    function bridge(uint256 dstChain, uint256 amountIn) external;
    function tokenBridgeCall(bytes memory data) external;
}

abstract contract TokenBridge is ITokenBridge, Auth, Pausable, PricingManaged, IDataReceiver {
    IDataBridge dataBridge;
    address public router;
    
    bytes32 BRIDGE_METHOD = keccak256("BRIDGE");
    
    address public treasury;
    address public staking;
    uint256 public protocolFee;
    uint256 constant feeDenominator = 10000;
    
    mapping (uint256 => uint256) public chainNetworkFee;
    mapping (uint256 => address) public chainTokenBridge;
    
    modifier supportedChain(uint256 chain) {
        require(chainTokenBridge[chain] != address(0), "UNSUPPORTED_CHAIN"); _;
    }
    
    constructor(IPricingManager _pricingManager, IDataBridge _bridge, address _router, address _treasury, address _staking, uint256 _protocolFee) Auth(msg.sender) PricingManaged(_pricingManager) {
        dataBridge = _bridge;
        router = _router;
        treasury = _treasury;
        staking = _staking;
        protocolFee = _protocolFee;
    }
    
    function setTokenBridge(uint256 chain, address tokenBridge) external onlyOwner {
        chainTokenBridge[chain] = tokenBridge;
        emit TokenBridgeUpdated(chain, tokenBridge);
    }
    
    function setProtocolFee(uint256 _fee) external onlyOwner {
        protocolFee = _fee;
        emit ProtocolFeeUpdated(_fee);
    }
    
    function setNetworkFee(uint256 chain, uint256 fee) external onlyOwner {
        chainNetworkFee[chain] = fee;
        emit NetworkFeeUpdated(chain, fee);
    }
    
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasuryUpdated(treasury);
    }
    
    function setStaking(address _staking) external onlyOwner {
        staking = _staking;
        emit StakingUpdated(staking);
    }
    
    function setRouter(address _router) external onlyOwner {
        router = _router;
        authorize(router);
        emit RouterUpdated(router);
    }
    
    function bridge(uint256 dstChain, uint256 amountIn, bytes memory routerData) external override notPaused authorized supportedChain(dstChain) {
        _takeTokens(msg.sender, amountIn);
        uint256 amount = _takeNetworkFee(dstChain, amountIn);
        _burnTokens();
        dataBridge.submitRequest(dstChain, chainTokenBridge[dstChain], BRIDGE_METHOD, abi.encode(amount, routerData));
    }
    
    function bridgeCall(uint256 fromChain, address fromAddress, bytes32 method, bytes memory data) external override {
        assert(msg.sender == address(dataBridge));
        assert(fromAddress == chainTokenBridge[fromChain]);
        require(method == BRIDGE_METHOD);
        (uint256 amountIn, bytes memory routerData) = abi.decode(data, (uint256, bytes));
        _mintTokens(amountIn);
        uint256 amount = _takeProtocolFee(amountIn);
        _sendTokens(router, amount);
        ITokenBridgeRouter(router).tokenBridgeCall(routerData);
    }
    
    function _takeNetworkFee(uint256 dstChain, uint256 amountIn) internal returns (uint256 amount) {
        uint256 fee = getBOGAmountForUSD(chainNetworkFee[dstChain], feeDenominator);
        require(amountIn > fee, "INSUFFICIENT_AMOUNT");
        _sendTokens(treasury, fee);
        amount = amountIn - fee;
    }
    
    function _takeProtocolFee(uint256 amountIn) internal returns (uint256 amount) {
        if(protocolFee > 0){
            uint256 fee = protocolFee * amountIn / feeDenominator;
            _sendTokens(staking, fee);
            amount = amountIn - fee;
        }else{
            return amountIn;
        }
    }
    
    function _takeTokens(address from, uint256 amount) internal virtual;
    function _sendTokens(address to, uint256 amount) internal virtual;
    function _mintTokens(uint256 amount) internal virtual;
    function _burnTokens() internal virtual;
    
    event TokenBridgeUpdated(uint256 chain, address indexed tokenBridge);
    event TreasuryUpdated(address indexed treasury);
    event StakingUpdated(address indexed staking);
    event ProtocolFeeUpdated(uint256 fee);
    event NetworkFeeUpdated(uint256 chain, uint256 fee);
    event RouterUpdated(address indexed router);
}

contract StandardTokenBridge is TokenBridge {
    IERC20 token;
    
    constructor(IERC20 _token, IPricingManager _pricingManager, IDataBridge _bridge, address _router, address _treasury, address _staking, uint256 _protocolFee)
    TokenBridge(_pricingManager, _bridge, _router, _treasury, _staking, _protocolFee)
    {
        token = _token;
    }
    
    function _takeTokens(address from, uint256 amount) internal virtual override {
        token.transferFrom(from, address(this), amount);
    }
    
    function _sendTokens(address to, uint256 amount) internal virtual override {
        token.transfer(to, amount);
    }
    
    function _mintTokens(uint256 amount) internal virtual override { }
    function _burnTokens() internal virtual override { }
}

contract MintableTokenBridge is TokenBridge {
    IERC20Mintable token;
    
    constructor(IERC20Mintable _token, IPricingManager _pricingManager, IDataBridge _bridge, address _router, address _treasury, address _staking, uint256 _protocolFee)
    TokenBridge(_pricingManager, _bridge, _router, _treasury, _staking, _protocolFee)
    {
        token = _token;
    }
    
    function _takeTokens(address from, uint256 amount) internal virtual override {
        token.transferFrom(from, address(this), amount);
    }
    
    function _sendTokens(address to, uint256 amount) internal virtual override {
        token.transfer(to, amount);
    }
    
    function _mintTokens(uint256 amount) internal virtual override { 
        token.mint(amount);
    }
    
    function _burnTokens() internal virtual override {
        token.burn(token.balanceOf(address(this)));
    }
    
    function returnTokenOwnership() external onlyOwner {
        token.transferOwnership(msg.sender);
    }
}

contract BasicTokenBridgeRouter is ITokenBridgeRouter {
    IERC20 token;
    TokenBridge tokenBridge;

    constructor (IERC20 _token, TokenBridge _tokenBridge) {
        token = _token;
        tokenBridge = _tokenBridge;
    }

    function bridge(uint256 dstChain, uint256 amountIn) external override {
        token.transferFrom(msg.sender, address(this), amountIn);
        token.approve(address(tokenBridge), amountIn);
        tokenBridge.bridge(dstChain, amountIn, abi.encode(msg.sender));
    }

    function tokenBridgeCall(bytes memory data) external override {
        require(msg.sender == address(tokenBridge));
        uint256 amount = token.balanceOf(address(this));
        address to = abi.decode(data, (address));
        token.transfer(to, amount);
    }
}
