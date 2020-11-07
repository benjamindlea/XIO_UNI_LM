pragma solidity ^0.6.7;


contract Ownable {
    address public owner;

    event TransferOwnership(address _from, address _to);

    constructor() public {
        owner = msg.sender;
        emit TransferOwnership(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    function setOwner(address _owner) external onlyOwner {
        emit TransferOwnership(owner, _owner);
        owner = _owner;
    }
}


contract XIO_LM is Ownable{
    
    using SafeMath for uint;
    
    uint constant ONE_DAY = 10;
    uint constant ONE_YEAR = ONE_DAY*365;
    uint constant MAX_PERIOD = ONE_YEAR*2;
    uint constant MAGIC_NUMBER = 1000000;
    bool constant baseToken0 = true;
    
    address public constant LIQUIDITY_TOKEN  = 0xEE89ea23c18410F2b57e7abc6eb24cfcdE4f49B0;
    address public constant REWARD_TOKEN  = 0xbBB38bE7c6D954320c0297c06Ab3265a950CDF89;

    mapping(address => mapping(uint => LiquidityRewardData)) public liquidityRewardData; //address to timestamp to data
   

    uint public totalLiquidityStaked;
    uint public unallocatedRewards;
    
    uint tokensInPool;
    uint ethInPool;
    uint liquidityTotalSupply;
 
    struct LiquidityRewardData {
        uint quantity;
        uint timestamp;
        uint period;
        uint reward;
        uint paid;
        
    }
    
     
    
    fallback()  external payable {
        revert();
    }
    
     function recoverERC20(address tokenAddress, uint256 tokenAmount) public onlyOwner {
        require(tokenAddress != LIQUIDITY_TOKEN);
        require(tokenAddress != REWARD_TOKEN);
        ERC20Token(tokenAddress).transfer(owner,tokenAmount);
    }
    
    function getUnallocatedRewards() view public returns(uint){
        return unallocatedRewards;
    }
   
     //assumes NOT FoT token
     function topupReward (uint amount)  external {
       require(ERC20Token(REWARD_TOKEN).transferFrom(address(msg.sender), address(this), amount),"tokenXferFail");
       unallocatedRewards += amount;
     } 
     
     function removeUnallocatedReward ()  external onlyOwner {
       require(ERC20Token(REWARD_TOKEN).transferFrom(address(this), address(msg.sender), unallocatedRewards),"tokenXferFail");
       unallocatedRewards = 0;
     } 
    
    
    function getRewardIndex(uint256 amount) public pure returns (uint) {
        if(     amount < 200000_000000000000000000){return 1000;} //10% Base Rate
        else if(amount < 400000_000000000000000000){return 2000;} //20% Base Rate
        else if(amount < 600000_000000000000000000){return 3000;} //30% Base Rate
        else if(amount < 800000_000000000000000000){return 4000;} //40% Base Rate
        else                                       {return 5000;} //50% Base Rate 
    }
    
    
    function getPeriodIndex(uint period) public pure returns (uint) {
        
        if(     period < 7*ONE_DAY ){return 100;} // 1x multiplier
        else if(period < 30*ONE_DAY){return 150;} // 1.5x multiplier
        else if(period < ONE_YEAR/2){return 300;} // 3x multiplier
        else if(period < ONE_YEAR ) {return 400;} // 4x multiplier
        else                        {return 500;} // 5x multiplier
        
    }
    
    
    
 
    
    function calcReward(uint period, uint liquidityToken)  public view returns (uint){
        
       uint amountTokens = (liquidityToken.mul(tokensInPool)).div(liquidityTotalSupply);
    
       uint baseRate = getRewardIndex(unallocatedRewards);
       uint multiplier =  getPeriodIndex(period);
       uint reward = (amountTokens.mul(period).mul(baseRate).mul(multiplier)).div(MAGIC_NUMBER*ONE_YEAR);
       
       require( reward <= unallocatedRewards, "notEnoughRewardRemaining");
        //check if stake crossed boundary, reward at lower rate.
        uint newBaseRate = getRewardIndex(unallocatedRewards - reward);
        if(newBaseRate < baseRate){
            reward = (amountTokens.mul(period).mul(newBaseRate).mul(multiplier)).div(MAGIC_NUMBER*ONE_YEAR);
        }
       return reward;
    }
    
     
    function lockLiquidity(uint idx, uint period, uint stakeTokens) external {
        require(period <= MAX_PERIOD,"tooLong");
        require((liquidityRewardData[msg.sender][idx].quantity == 0),"previousLiquidityInSlot");
        require(ERC20Token(LIQUIDITY_TOKEN).transferFrom(address(msg.sender), address(this), stakeTokens),"tokenXferFail");
        totalLiquidityStaked += stakeTokens;
        stakeLiquidity(idx, period, stakeTokens);
    }
    
    function unlockLiquidity(uint idx) external { //get liquidity tokens
        require(liquidityRewardData[msg.sender][idx].quantity > 0,"nothingStakedHere");
        require(liquidityRewardData[msg.sender][idx].timestamp.add( liquidityRewardData[msg.sender][idx].period) <= block.timestamp,"stakeNotElapsed");
        claim(idx);
        totalLiquidityStaked -= liquidityRewardData[msg.sender][idx].quantity;
        ERC20Token(LIQUIDITY_TOKEN).transfer(address(msg.sender),liquidityRewardData[msg.sender][idx].quantity);
        delete liquidityRewardData[msg.sender][idx];
       
        
    }
    
    function update() public  {
        if(msg.sender == tx.origin){ //prevent flashloan exploit
          if(baseToken0==true){
            (tokensInPool, ,) = Uniswap2PairContract(LIQUIDITY_TOKEN).getReserves();
          }
          else{
              ( ,tokensInPool,) = Uniswap2PairContract(LIQUIDITY_TOKEN).getReserves();
          }
          liquidityTotalSupply = ERC20Token(LIQUIDITY_TOKEN).totalSupply();
        }
    }
    
        
    function stakeLiquidity(uint idx, uint period, uint stakeTokens) private  {
        update();
        uint reward = calcReward(period,stakeTokens);
        unallocatedRewards -= reward;
       
        liquidityRewardData[msg.sender][idx] = LiquidityRewardData(stakeTokens, block.timestamp, period, reward, 0);
    }
    
    
    function earned(uint idx) public view returns (uint){
        if( liquidityRewardData[msg.sender][idx].timestamp.add( 
                liquidityRewardData[msg.sender][idx].period) <= block.timestamp){
            return liquidityRewardData[msg.sender][idx].reward - liquidityRewardData[msg.sender][idx].paid;
        }
        else{
            uint secondsSinceStake  = block.timestamp - liquidityRewardData[msg.sender][idx].timestamp;
            return ((secondsSinceStake*liquidityRewardData[msg.sender][idx].reward)/liquidityRewardData[msg.sender][idx].period) - liquidityRewardData[msg.sender][idx].paid;
        }
        
    }
        
    function claim(uint idx) public {
        uint claimAmount = earned(idx);
        liquidityRewardData[msg.sender][idx].paid += claimAmount;
        ERC20Token(REWARD_TOKEN).transfer(address(msg.sender), claimAmount);
    }
    
    
    function renew(uint idx, uint renewPeriod) external {
        require(liquidityRewardData[msg.sender][idx].timestamp.add( liquidityRewardData[msg.sender][idx].period) <= block.timestamp,"stakeNotElapsed");
        claim(idx);
        stakeLiquidity(idx, renewPeriod, liquidityRewardData[msg.sender][idx].quantity) ;
    }
}

 
interface Uniswap2PairContract {
  
  function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
  }

interface ERC20Token {
  function totalSupply() external view returns (uint);
  function approve(address spender, uint value)  external returns (bool);
  function balanceOf(address owner) external returns (uint);
  function transfer (address to, uint value) external returns (bool);
  function transferFrom (address from, address to, uint value) external returns (bool);
}



library SafeMath {
  function mul(uint a, uint b) internal pure returns (uint) {
    if (a == 0) {
      return 0;
    }
    uint c = a * b;
    assert(c / a == b);
    return c;
  }

  function div(uint a, uint b) internal pure returns (uint) {
    uint c = a / b;
    return c;
  }

  function sub(uint a, uint b) internal pure returns (uint) {
    assert(b <= a);
    return a - b;
  }

  function add(uint a, uint b) internal pure returns (uint) {
    uint c = a + b;
    assert(c >= a);
    return c;
  }

  function ceil(uint a, uint m) internal pure returns (uint) {
    uint c = add(a,m);
    uint d = sub(c,1);
    return mul(div(d,m),m);
  }
}


