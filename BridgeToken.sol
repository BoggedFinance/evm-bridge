//SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint256);
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

abstract contract Ownable {
    address owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!OWNER"); _;
    }

    function transferOwnership(address adr) external onlyOwner {
        owner = adr;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
}

contract BOG is IERC20, Ownable {
    string public override name = "Bogged Finance";
    string public override symbol = "BOG";
    uint256 public override decimals = 18;
    
    uint256 public override totalSupply = 0;
    uint256 public constant maxSupply = 15_000_000 * (10 ** 18);
    
    mapping (address => uint256) balances;
    mapping (address => mapping (address => uint256)) allowances;
    
    uint256 public buyFee;
    uint256 public sellFee;
    uint256 public feeDenominator;
    address public feeReceiver;
    mapping (address => bool) public hasBuyFee;
    mapping (address => bool) public hasSellFee;
    mapping (address => bool) public isFeeExempt;
    
    function getOwner() external view override returns (address) {
        return owner;
    }
    
    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }
    
    function allowance(address _owner, address spender) external view override returns (uint256) {
        return allowances[_owner][spender];
    }
    
    function approve(address spender, uint256 amount) external override returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(allowances[sender][msg.sender] >= amount, "Insufficient Allowance");
        allowances[sender][msg.sender] -= amount;
        _transfer(sender, recipient, amount);
        return true;
    }
    
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(balances[sender] >= amount, "Insufficient Balance");
        balances[sender] -= amount;
        amount = takeFee(sender, recipient, amount);
        balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }
    
    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {
        if(isFeeExempt[sender] || isFeeExempt[recipient]){
            return amount;
        }
            
        uint256 feeAmount;
        
        if(buyFee > 0 && hasBuyFee[sender]){
            feeAmount += buyFee * amount / feeDenominator;
        }
        
        if(sellFee > 0 && hasSellFee[recipient]){
            feeAmount += sellFee * amount / feeDenominator;
        }
        
        if(feeAmount > 0){
            balances[feeReceiver] += feeAmount;
            emit Transfer(sender, feeReceiver, feeAmount);
            return amount - feeAmount;
        }
        
        return amount;
    }
    
    function setFees(uint256 _buyFee, uint256 _sellFee, uint256 _denominator, address _receiver) external onlyOwner {
        require(_buyFee + _sellFee <= _denominator / 20, "Total fee must not exceed 5%");
        buyFee = _buyFee;
        sellFee = _sellFee;
        feeDenominator = _denominator;
        feeReceiver = _receiver;
        emit FeesUpdated(buyFee, sellFee, feeDenominator, feeReceiver);
    }
    
    function setHasFee(address adr, bool _buyFee, bool _sellFee) external onlyOwner {
        hasBuyFee[adr] = _buyFee;
        hasSellFee[adr] = _sellFee;
        emit HasFeeUpdated(adr, _buyFee, _sellFee);
    }
    
    function setIsFeeExempt(address adr, bool exempt) external onlyOwner {
        isFeeExempt[adr] = exempt;
        emit IsFeeExemptUpdated(adr, exempt);
    }
    
    function burn(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient Balance");
        balances[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
    
    function mint(uint256 amount) external onlyOwner {
        balances[msg.sender] += amount;
        totalSupply += amount;
        assert(totalSupply <= maxSupply);
        emit Transfer(address(0), msg.sender, amount);
    }
    
    event FeesUpdated(uint256 buyFee, uint256 sellFee, uint256 feeDenominator, address feeReceiver);
    event HasFeeUpdated(address adr, bool hasBuyFee, bool hasSellFee);
    event IsFeeExemptUpdated(address adr, bool exempt);
}


