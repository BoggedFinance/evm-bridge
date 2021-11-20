//SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "./ECDSA.sol";

abstract contract Auth {
    address owner;
    mapping (address => bool) private authorizations;

    constructor(address _owner) {
        owner = _owner;
        authorizations[_owner] = true;
    }

    modifier onlyOwner() {
        require(isOwner(msg.sender), "DataBridge: ONLY_OWNER"); _;
    }

    modifier authorized() {
        require(isAuthorized(msg.sender), "DataBridge: ONLY_AUTHORIZED"); _;
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
        require(paused, "DataBridge: NOT_PAUSED"); 
        _;
    }

    modifier notPaused() {
        require(!paused, "DataBridge: PAUSED"); 
        _;
    }

    function pause() external authorized {
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
        uint256 nonce;
        uint256 dstChain;
        address sender;
        address receiver;
        bytes32 method;
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

interface IBridgeDataReceiver {
    function bridgeCall(uint256 fromChain, address fromAddress, bytes32 method, bytes memory data) external;
}

contract DataBridge is IDataBridge, Auth, Pausable {
    using ECDSA for bytes32;
    
    bytes4 BRIDGE_CALL_SELECTOR = bytes4(keccak256(bytes("bridgeCall(uint256,address,bytes32,bytes)")));
    
    mapping (uint256 => bool) public supportedChain;
    
    uint256 public count;
    // srcChainId => nonce => request
    mapping (uint256 => mapping (uint256 => Request)) public requests;
    // srcChainId => nonce => status
    mapping (uint256 => mapping (uint256 => RequestStatus)) public requestStatus;
    
    mapping (address => bool) private relayers;
    
    uint256 public signatureThreshold = 2;
    mapping (address => bool) private signers;
    mapping (uint256 => mapping (uint256 => mapping (address => bool))) private signed;
    
    constructor (uint256[] memory _chains, address[] memory _relayers, address[] memory _signers) Auth(msg.sender) {
        for(uint256 i = 0; i<_chains.length; i++){
            supportedChain[_chains[i]] = true;
        }
        for(uint256 i = 0; i<_relayers.length; i++){
            relayers[_relayers[i]] = true;
        }
        for(uint256 i = 0; i<_signers.length; i++){
            signers[_signers[i]] = true;
        }
    }
    
    modifier onlyRelayer() {
        require(relayers[msg.sender], "DataBridge: ONLY_RELAYER");
        _;
    }
    
    function setRelayer(address relayer, bool state) external onlyOwner {
        relayers[relayer] = state;
        emit RelayerUpdated(relayer, state);
    }
    
    function setSigner(address signer, bool state) external onlyOwner {
        signers[signer] = state;
        emit SignerUpdated(signer, state); 
    }
    
    function setSignatureThreshold(uint256 amount) external onlyOwner {
        require(amount >= 2, "DataBridge: UNDER_MIN_SIGNATURES");
        signatureThreshold = amount;
        emit SignatureThresholdUpdated(amount);
    }
    
    function setSupportedChain(uint256 chain, bool state) external onlyOwner {
        require(chain != block.chainid, "DataBridge: INVALID_CHAIN");
        supportedChain[chain] = state;
        emit SupportedChainUpdated(chain, state);
    }
    
    function submitRequest(uint256 dstChain, address receiver, bytes32 method, bytes memory data) external authorized notPaused override returns (uint256 nonce) {
        require(supportedChain[dstChain], "DataBridge: INVALID_DEST");
        Request memory req = Request({
            srcChain: block.chainid,
            nonce: count++,
            dstChain: dstChain,
            sender: msg.sender,
            receiver: receiver,
            method: method,
            data: data
        });
        
        requests[req.srcChain][req.nonce] = req;
        
        emit RequestSubmitted(req);
        
        return req.nonce;
    }
    
    function fulfilRequest(Request memory req, bytes[] memory signatures) external onlyRelayer notPaused override {
        require(requestStatus[req.srcChain][req.nonce] == RequestStatus.PENDING, "DataBridge: ONLY_PENDING");
        require(req.dstChain == block.chainid, "DataBridge: INVALID_CHAIN");
        verifySignatures(req, signatures);
        requests[req.srcChain][req.nonce] = req;
        
        (bool success, ) = req.receiver.call(abi.encodeWithSelector(BRIDGE_CALL_SELECTOR, req.srcChain, req.sender, req.method, req.data));
        requestStatus[req.srcChain][req.nonce] = success ? RequestStatus.SUCCESS : RequestStatus.FAILED;
        
        emit RequestReceived(req, requestStatus[req.srcChain][req.nonce]);
    }
    
    function cancelRequest(Request memory req, bytes[] memory signatures) external onlyRelayer notPaused override {
        require(requestStatus[req.srcChain][req.nonce] == RequestStatus.PENDING, "DataBridge: ONLY_PENDING");
        require(req.dstChain == block.chainid, "DataBridge: INVALID_CHAIN");
        verifySignatures(req, signatures);
        requests[req.srcChain][req.nonce] = req;
        
        requestStatus[req.srcChain][req.nonce] = RequestStatus.FAILED;
        
        emit RequestReceived(req, requestStatus[req.srcChain][req.nonce]);
    }
    
    function verifySignatures(Request memory req, bytes[] memory signatures) internal {
        require(signatures.length >= signatureThreshold, "DataBridge: INSUFFICIENT_SIGNATURES");
        
        bytes32 hash = getRequestMessageHash(req);
        
        for(uint256 i; i<signatures.length; i++){
            address signer = hash.recover(signatures[i]);
            require(signers[signer], "DataBridge: NOT_SIGNER");
            require(!signed[req.srcChain][req.nonce][signer], "DataBridge: DUPLICATE_SIGNATURE");
            signed[req.srcChain][req.nonce][signer] = true;
        }
    }
    
    function getOutgoingRequestHash(uint256 nonce) external view returns (bytes32) {
        return getRequestHash(requests[block.chainid][nonce]);
    }
    
    function getRequestHash(Request memory req) internal pure returns (bytes32) {
        return keccak256(getEncodedRequest(req));
    }
    
    function getRequestMessageHash(Request memory req) internal pure returns (bytes32) {
        return getRequestHash(req).toEthSignedMessageHash();
    }
    
    function getEncodedRequest(Request memory req) internal pure returns (bytes memory) {
        return abi.encode(req.srcChain, req.nonce, req.dstChain, req.sender, req.receiver, req.method, req.data);
    }
}

