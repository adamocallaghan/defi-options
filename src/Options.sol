pragma solidity ^0.6.7;

import
    "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.6/interfaces/LinkTokenInterface.sol";
import
    "https://github.com/smartcontractkit/chainlink/blob/master/evm-contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";

contract chainlinkOptions {
    //Pricefeed interfaces
    AggregatorV3Interface internal ethFeed;
    AggregatorV3Interface internal linkFeed;
    //Interface for LINK token functions
    LinkTokenInterface internal LINK;
    uint256 ethPrice;
    uint256 linkPrice;
    //Precomputing hash of strings
    bytes32 ethHash = keccak256(abi.encodePacked("ETH"));
    bytes32 linkHash = keccak256(abi.encodePacked("LINK"));
    address payable contractAddr;

    //Options stored in arrays of structs
    struct option {
        uint256 strike; //Price in USD (18 decimal places) option allows buyer to purchase tokens at
        uint256 premium; //Fee in contract token that option writer charges
        uint256 expiry; //Unix timestamp of expiration time
        uint256 amount; //Amount of tokens the option contract is for
        bool exercised; //Has option been exercised
        uint256 id; //Unique ID of option, also array index
        uint256 latestCost; //Helper to show last updated cost to exercise
        address payable writer; //Issuer of option
        address payable buyer; //Buyer of option
    }

    option[] public ethOpts;
    option[] public linkOpts;

    //Kovan feeds: https://docs.chain.link/docs/reference-contracts
    constructor() public {
        //ETH/USD Kovan feed
        ethFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
        //LINK/USD Kovan feed
        linkFeed = AggregatorV3Interface(0x396c5E36DD0a0F5a5D33dae44368D4193f69a1F0);
        //LINK token address on Kovan
        LINK = LinkTokenInterface(0xa36085F69e2889c224210F603D836748e7dC0088);
        contractAddr = payable(address(this));
    }

    //Returns the latest ETH price
    function getEthPrice() public view returns (uint256) {
        (uint80 roundID, int256 price, uint256 startedAt, uint256 timeStamp, uint80 answeredInRound) =
            ethFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        //Price should never be negative thus cast int to unit is ok
        //Price is 8 decimal places and will require 1e10 correction later to 18 places
        return uint256(price);
    }

    //Returns the latest LINK price
    function getLinkPrice() public view returns (uint256) {
        (uint80 roundID, int256 price, uint256 startedAt, uint256 timeStamp, uint80 answeredInRound) =
            linkFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        //Price should never be negative thus cast int to unit is ok
        //Price is 8 decimal places and will require 1e10 correction later to 18 places
        return uint256(price);
    }

    //Updates prices to latest
    function updatePrices() internal {
        ethPrice = getEthPrice();
        linkPrice = getLinkPrice();
    }

    //Allows user to write a covered call option
    //Takes which token, a strike price(USD per token w/18 decimal places), premium(same unit as token), expiration time(unix) and how many tokens the contract is for
    function writeOption(string memory token, uint256 strike, uint256 premium, uint256 expiry, uint256 tknAmt)
        public
        payable
    {
        bytes32 tokenHash = keccak256(abi.encodePacked(token));
        require(tokenHash == ethHash || tokenHash == linkHash, "Only ETH and LINK tokens are supported");
        updatePrices();
        if (tokenHash == ethHash) {
            require(msg.value == tknAmt, "Incorrect amount of ETH supplied");
            uint256 latestCost = (strike * tknAmt) / (ethPrice * 10 ** 10); //current cost to exercise in ETH, decimal places corrected
            ethOpts.push(
                option(strike, premium, expiry, tknAmt, false, ethOpts.length, latestCost, msg.sender, address(0))
            );
        } else {
            require(LINK.transferFrom(msg.sender, contractAddr, tknAmt), "Incorrect amount of LINK supplied");
            uint256 latestCost = (strike * tknAmt) / (linkPrice * 10 ** 10);
            linkOpts.push(
                option(strike, premium, expiry, tknAmt, false, linkOpts.length, latestCost, msg.sender, address(0))
            );
        }
    }

    //Purchase a call option, needs desired token, ID of option and payment
    function buyOption(string memory token, uint256 ID) public payable {
        bytes32 tokenHash = keccak256(abi.encodePacked(token));
        require(tokenHash == ethHash || tokenHash == linkHash, "Only ETH and LINK tokens are supported");
        updatePrices();
        if (tokenHash == ethHash) {
            //Transfer premium payment from buyer
            require(msg.value == ethOpts[ID].premium, "Incorrect amount of ETH sent for premium");
            //Transfer premium payment to writer
            ethOpts[ID].writer.transfer(ethOpts[ID].premium);
            ethOpts[ID].buyer = msg.sender;
        } else {
            //Transfer premium payment from buyer to writer
            require(
                LINK.transferFrom(msg.sender, linkOpts[ID].writer, linkOpts[ID].premium),
                "Incorrect amount of LINK sent for premium"
            );
            linkOpts[ID].buyer = msg.sender;
        }
    }

    //Exercise your call option, needs desired token, ID of option and payment
    function exercise(string memory token, uint256 ID) public payable {
        //If not expired and not already exercised, allow option owner to exercise
        //To exercise, the strike value*amount equivalent paid to writer (from buyer) and amount of tokens in the contract paid to buyer
        bytes32 tokenHash = keccak256(abi.encodePacked(token));
        require(tokenHash == ethHash || tokenHash == linkHash, "Only ETH and LINK tokens are supported");
        if (tokenHash == ethHash) {
            require(ethOpts[ID].buyer == msg.sender, "You do not own this option");
            require(!ethOpts[ID].exercised, "Option has already been exercised");
            require(ethOpts[ID].expiry >= now, "Option is expired");
            //Conditions are met, proceed to payouts
            updatePrices();
            //Cost to exercise
            uint256 exerciseVal = ethOpts[ID].strike * ethOpts[ID].amount;
            //Equivalent ETH value using Chainlink feed
            uint256 equivEth = exerciseVal / (ethPrice * 10 ** 10); //move decimal 10 places right to account for 8 places of pricefeed
            //Buyer exercises option by paying strike*amount equivalent ETH value
            require(msg.value == equivEth, "Incorrect LINK amount sent to exercise");
            //Pay writer the exercise cost
            ethOpts[ID].writer.transfer(equivEth);
            //Pay buyer contract amount of ETH
            msg.sender.transfer(ethOpts[ID].amount);
            ethOpts[ID].exercised = true;
        } else {
            require(linkOpts[ID].buyer == msg.sender, "You do not own this option");
            require(!linkOpts[ID].exercised, "Option has already been exercised");
            require(linkOpts[ID].expiry >= now, "Option is expired");
            updatePrices();
            uint256 exerciseVal = linkOpts[ID].strike * linkOpts[ID].amount;
            uint256 equivLink = exerciseVal / (linkPrice * 10 ** 10);
            //Buyer exercises option, exercise cost paid to writer
            require(
                LINK.transferFrom(msg.sender, linkOpts[ID].writer, equivLink), "Incorrect LINK amount sent to exercise"
            );
            //Pay buyer contract amount of LINK
            require(LINK.transfer(msg.sender, linkOpts[ID].amount), "Error: buyer was not paid");
            linkOpts[ID].exercised = true;
        }
    }

    //This is a helper function to help the user see what the cost to exercise an option is currently before they do so
    //Updates lastestCost member of option which is publicly viewable
    function updateExerciseCost(string memory token, uint256 ID) public {
        bytes32 tokenHash = keccak256(abi.encodePacked(token));
        require(tokenHash == ethHash || tokenHash == linkHash, "Only ETH and LINK tokens are supported");
        updatePrices();
        if (tokenHash == ethHash) {
            ethOpts[ID].latestCost = ethOpts[ID].strike * ethOpts[ID].amount / (ethPrice * 10 ** 10);
        } else {
            linkOpts[ID].latestCost = linkOpts[ID].strike * linkOpts[ID].amount / (linkPrice * 10 ** 10);
        }
    }
}
