//SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

library SafeMath {

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) { return 0; }
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }
}

interface IBEP20 {
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

interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IDividendDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {

    using SafeMath for uint256;
    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;
    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 constant public dividendsPerShareAccuracyFactor = 10 ** 18;

    uint256 public minPeriod = 30 minutes;
    uint256 public minDistribution = 0.01 ether;

    uint256 currentIndex;

    modifier onlyToken() {
        require(msg.sender == _token, "only token"); _;
    }

    constructor () {
        _token = msg.sender;
    }

    function setDistributionCriteria(uint256 newMinPeriod, uint256 newMinDistribution) external override onlyToken {
        minPeriod = newMinPeriod;
        minDistribution = newMinDistribution;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {

        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 amount = msg.value;
        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 iterations = 0;
        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        while(gasUsed < gas && iterations < shareholderCount) {

            if(currentIndex >= shareholderCount){ currentIndex = 0; }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            payable(shareholder).transfer(amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }
    
    function claimDividend() external {
        require(shouldDistribute(msg.sender), "Too soon. Need to wait!");
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() external virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) external virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract BoM is IBEP20, Ownable {
    
    using SafeMath for uint256;

    string constant _name = "Babies Of Mars";
    string constant _symbol = "BoM";
    uint8  constant _decimals = 18;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant routerAddress = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 constant _totalSupply = 1 * 10**15 * (10 ** _decimals);
    uint256 public   _sellTxAmount = _totalSupply * 5 / 1000;
    uint256 public   _maxTxAmount = _totalSupply * 3 / 100;
    uint256 public   _walletMax = _totalSupply * 5 / 100;
    
    bool public restrictWhales = true;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    mapping (address => bool) public isFeeExempt;
    mapping (address => bool) public isTxLimitExempt;
    mapping (address => bool) public isDividendExempt;

    uint256 public BoMHoldersRewardFee = 5;
    uint256 public NFTHoldersRewardFee = 5;
    uint256 public buyBackFee = 3;
    uint256 public marketingFee = 2;
    uint256 public extraSellFee = 10;

    uint256 public totalFee = 0;
    uint256 public totalFeeIfSelling = 0;

    address public marketing;
    address public NFT_DividendDistributor;

    IDEXRouter public router;
    address public pair;

    uint256 public launchedAt;
    bool public tradingOpen = false;
    bool public feeStatus = true;
    bool public feeBasicStatus = false;

    uint256 public buyBackTokenBalance;
    uint256 public buyBackBNBBalance;
    bool    public autoBuyBack = false;
    uint256 public buyBackThreshold = 0.1 ether;
    uint256 public buyBackSellCondition = 10;
    uint256 public buyBackSellCnt;

    DividendDistributor public BoM_DividendDistributor;
    uint256 distributorGas = 500000;

    bool inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = true;

    uint256 public swapThreshold = _totalSupply * 1 / 1000;

    
    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }
    
    event AutoLiquify(uint256 amountBNB, uint256 amountMETA);
    
    constructor (address marketingAddr, address NFTAddr) {
        require(marketingAddr != address(0), "invalid marketing address");
        require(NFTAddr != address(0), "invalid NFT address");

        marketing = marketingAddr;
        NFT_DividendDistributor = NFTAddr;
        
        router = IDEXRouter(routerAddress);
        pair = IDEXFactory(router.factory()).createPair(router.WETH(), address(this));
        _allowances[address(this)][address(router)] =  type(uint256).max;

        BoM_DividendDistributor = new DividendDistributor();

        isFeeExempt[msg.sender] = true;
        isFeeExempt[address(this)] = true;

        isTxLimitExempt[msg.sender] = true;
        isTxLimitExempt[pair] = true;
        isTxLimitExempt[DEAD] = true;

        isDividendExempt[pair] = true;
        isDividendExempt[msg.sender] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[DEAD] = true;
        
        totalFee = BoMHoldersRewardFee.add(NFTHoldersRewardFee);
        totalFeeIfSelling = totalFee.add(buyBackFee).add(marketingFee);

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable { }

    function name() external pure override returns (string memory) { return _name; }
    function symbol() external pure override returns (string memory) { return _symbol; }
    function decimals() external pure override returns (uint8) { return _decimals; }
    function totalSupply() external pure override returns (uint256) { return _totalSupply; }

    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD));
    }

    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool)
    {
        _allowances[msg.sender][spender] = _allowances[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool)
    {
        uint256 oldValue = _allowances[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowances[msg.sender][spender] = 0;
        } else {
            _allowances[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function launched() internal view returns (bool) {
        return launchedAt != 0;
    }

    function launch() internal {
        launchedAt = block.number;
    }

    function changeTxLimit(uint256 newLimit) external onlyOwner {
        require(newLimit >= (_totalSupply * 1 / 100) && newLimit <= _totalSupply , "invalid amount"); // min:1% max:100% current: 3%
        _maxTxAmount = newLimit;
    }

    function changeSellTxLimit(uint256 newLimit) external onlyOwner {
        require(newLimit >= (_totalSupply * 1 / 1000) && newLimit <= _totalSupply , "invalid amount");  // min:0.1% max:100%  current: 0.5%
        _sellTxAmount = newLimit;
    }

    function changeWalletLimit(uint256 newLimit) external onlyOwner {
        require(newLimit >= (_totalSupply * 1 / 100) && newLimit <= _totalSupply , "invalid amount"); // min:1% max:100%  current: 5%
        _walletMax  = newLimit;
    }

    function changeBuyBackThreshold(uint256 newLimit) external onlyOwner {
        require(newLimit >= 0.001 ether && newLimit <= 100 ether , "invalid amount"); // min:0.001 BNB max:100 BNB  current: 0.1 BNB
        buyBackThreshold  = newLimit;
    }

    function changeBuyBackSellCondition(uint256 newLimit) external onlyOwner {
        require(newLimit >= 1 && newLimit <= 1000 , "invalid amount");    // min:1 max:1000  current: 10
        buyBackSellCondition  = newLimit;
    }

    function changeRestrictWhales(bool newValue) external onlyOwner {
        require(newValue != restrictWhales , "invalid status"); 
        restrictWhales = newValue;
    }
    
    function changeIsFeeExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && isFeeExempt[holder] != exempt , "invalid status");
        isFeeExempt[holder] = exempt;
    }

    function changeIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && isTxLimitExempt[holder] != exempt , "invalid status");
        isTxLimitExempt[holder] = exempt;
    }

    function changeIsDividendExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && holder != pair, "invalid holder");
        isDividendExempt[holder] = exempt;
        
        if(exempt){
            BoM_DividendDistributor.setShare(holder, 0);
        }else{
            BoM_DividendDistributor.setShare(holder, _balances[holder]);
        }
    }

    function changeFees(uint256 newBoM, uint256 newNFT, uint256 newBuyBack, uint256 newMarketing) external onlyOwner {
        require(newBoM >= 0 && newBoM <= 15 , "invalid BoM amount");
        require(newNFT >= 0 && newNFT <= 15 , "invalid NFT amount");
        require(newBuyBack >= 0 && newBuyBack <= 10 , "invalid BuyBack amount");
        require(newMarketing >= 0 && newMarketing <= 10 , "invalid Marketing amount");

        BoMHoldersRewardFee = newBoM;
        NFTHoldersRewardFee = newNFT;
        buyBackFee = newBuyBack;
        marketingFee = newMarketing;
        
        totalFee = BoMHoldersRewardFee.add(NFTHoldersRewardFee);
        totalFeeIfSelling = totalFee.add(buyBackFee).add(marketingFee);
    }

    function changeExtraSellFee(uint256 newFee) external onlyOwner {
        require(newFee >= 0 && newFee <= 20 , "invalid SellFee amount");
        extraSellFee = newFee;
    }

    function changeMarketing(address newAddr) external onlyOwner {
        require(newAddr != address(0), "invalid address");
        marketing = newAddr;
    }

    function changeNFTAddr(address newAddr) external onlyOwner {
        require(newAddr != address(0), "invalid address");
        NFT_DividendDistributor = newAddr;
    }

    function changeSwapBackSettings(bool enableSwapBack, uint256 newSwapBackLimit) external onlyOwner {
        require(newSwapBackLimit >= (_totalSupply * 1 / 10000) && newSwapBackLimit <= _totalSupply , "invalid swapThreshold amount"); // min:0.01% max:100%  current: 0.1%
        swapAndLiquifyEnabled  = enableSwapBack;
        swapThreshold = newSwapBackLimit;
    }

    function changeDistributionCriteria(uint256 newinPeriod, uint256 newMinDistribution) external onlyOwner {
        require(newinPeriod >= 1 minutes && newinPeriod <= 2 days , "invalid period amount");
        require(newMinDistribution >= 0.001 ether && newMinDistribution <= 1 ether , "invalid distribution amount");
        BoM_DividendDistributor.setDistributionCriteria(newinPeriod, newMinDistribution);
    }

    function changeDistributorSettings(uint256 gas) external onlyOwner {
        require(gas < 1500000, "invalid gas fee");
        distributorGas = gas;
    }
    
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }
        return _transferFrom(sender, recipient, amount);
    }

    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        
        if(inSwapAndLiquify){ return _basicTransfer(sender, recipient, amount); }

        if(sender != owner() && recipient != owner()){
            require(tradingOpen, "Trading not open yet");
        }

        require(amount <= _maxTxAmount || isTxLimitExempt[sender], "TX Limit Exceeded");

        if(msg.sender != pair && !inSwapAndLiquify && swapAndLiquifyEnabled && _balances[address(this)] >= swapThreshold){
             swapBack(); 
        }

        //auto buyback
        if(pair == recipient){
            buyBackSellCnt++;
            if(buyBackSellCnt == buyBackSellCondition){
                buyBackSellCnt = 0;
                if(msg.sender != pair && !inSwapAndLiquify && autoBuyBack && buyBackBNBBalance >= buyBackThreshold){
                    buyBackSwap(buyBackBNBBalance); 
                }
            }
        }


        if(!launched() && recipient == pair) {
            require(_balances[sender] > 0, "no balance");
            launch();
        }

        //Exchange tokens
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        
        if(!isTxLimitExempt[recipient] && restrictWhales)
        {
            require(_balances[recipient].add(amount) <= _walletMax, "max wallet limit reached");
        }

        uint256 finalAmount = !isFeeExempt[sender] && !isFeeExempt[recipient] && feeStatus ? takeFee(sender, recipient, amount) : amount;
        _balances[recipient] = _balances[recipient].add(finalAmount);

        // Dividend tracker
        if(!isDividendExempt[sender]) {
            try BoM_DividendDistributor.setShare(sender, _balances[sender]) {} catch {}
        }

        if(!isDividendExempt[recipient]) {
            try BoM_DividendDistributor.setShare(recipient, _balances[recipient]) {} catch {} 
        }

        try BoM_DividendDistributor.process(distributorGas) {} catch {}

        emit Transfer(sender, recipient, finalAmount);
        return true;
    }
    
    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {

        if(sender == pair || recipient == pair || feeBasicStatus){
            uint256 feeApplicable = pair == recipient ? totalFeeIfSelling : totalFee;
            uint256 feeAmount = amount.mul(feeApplicable).div(100);

            if(pair == recipient){
                uint256 mFee = feeAmount.mul(marketingFee).div(totalFeeIfSelling);
                _balances[marketing] = _balances[marketing].add(mFee);
                emit Transfer(sender, marketing, feeAmount);
                uint256 bFee = feeAmount.mul(buyBackFee).div(totalFeeIfSelling);
                buyBackTokenBalance = buyBackTokenBalance.add(bFee);
                feeAmount = feeAmount.sub(mFee);
                if(amount > _sellTxAmount){
                    uint256 extraFeeAmount = amount.mul(extraSellFee).div(100);
                    buyBackTokenBalance = buyBackTokenBalance.add(extraFeeAmount);
                    feeAmount = feeAmount.add(extraFeeAmount);
                }
            }

            _balances[address(this)] = _balances[address(this)].add(feeAmount);
            emit Transfer(sender, address(this), feeAmount);

            return amount.sub(feeAmount);
        }
        else{
            return amount;
        }
    }

    function tradingStatus(bool newStatus) external onlyOwner {
        require(tradingOpen != newStatus , "invalid status");
        tradingOpen = newStatus;
    }

    function changeFeeStatus(bool newStatus) external onlyOwner {
        require(feeStatus != newStatus , "invalid status");
        feeStatus = newStatus;
    }

    function changeFeeBasicStatus(bool newStatus) external onlyOwner {
        require(feeBasicStatus != newStatus , "invalid status");
        feeBasicStatus = newStatus;
    }

    function swapBack() internal lockTheSwap {
        uint256 amountToSwap = _balances[address(this)];
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp.add(20)
        );

        uint256 amountBNB = address(this).balance;
        if(amountBNB > buyBackBNBBalance){
            amountBNB = amountBNB.sub(buyBackBNBBalance);
            uint256 buyBackAmount = amountBNB.mul(buyBackTokenBalance).div(amountToSwap);
            buyBackBNBBalance = buyBackBNBBalance.add(buyBackAmount);
            buyBackTokenBalance = 0;
            uint256 amountBNBBoM = (amountBNB.sub(buyBackAmount)).div(2);
            uint256 amountBNBNFT = amountBNBBoM;

            try BoM_DividendDistributor.deposit{value: amountBNBBoM}() {} catch {}
            payable(NFT_DividendDistributor).transfer(amountBNBNFT);
        }
          
    }

    function setAutoBuyBack(bool newStatus) external onlyOwner {
        require(autoBuyBack != newStatus , "invalid status");
        autoBuyBack = newStatus;
    }

    function buyBack(uint256 amount) external onlyOwner {
        require(amount <= buyBackBNBBalance,"invalid amount");
        require(amount <= address(this).balance,"invalid amount");
        buyBackSwap(amount);
    }

    function buyBackSwap(uint256 amount) internal lockTheSwap {
        
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(this);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            DEAD,
            block.timestamp.add(20)
        );
 
    }
}
/* (c) BoM */