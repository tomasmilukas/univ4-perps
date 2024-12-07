## PerpDexHook


## Problem / Background: What inspired the idea? What problems are you solving?

The main inspiration was to make liquidity more efficient in CLMMs. At any instance, only liquidity at the current tick matters, so there is a lot of opportunity to leverage free liquidity. I also like to push boundaries :).

For LPs, this hook design should be interesting since it's their job to predict ranges, while on the opposite side traders look to break ranges with directional bets. So successful LPers should gain a lot more from this in comparison to average or unprofitable LPers. However, on aggregate, traders tend to lose money with directional bets, so all LPers should profit from this type of hook.

 ## Impact: What makes this project unique? What impact will this make? 

The project is unique since the majority of liquidity related projects are about active LPing or putting idle (out of range) funds into lending pools on aave/morpho. This will allow LPers to earn additional yield while they are earning yield on their main swaps. It is an impactful project because it allows to double dip yield in a unique way that makes sense, renting out spot capital for perps.

Also, while we do lock liquidity for collateral, LPers (in the future, not in the current design) will be able to change their ranges atomically and not affect the traders underlying collateral. This is an interesting design since if you are priced out in a ETH/UNI pool and you are full ETH, you can simply place a position right below the current tick to rebalance to 50/50 (or any ratio needed) and then LP into any position needed.

## Challenges: What was challenging about building this project? 

Designing a safe and efficient architecture has been challenging, and in its current format, it's neither safe nor efficient. 

The main struggles have been liquidity lockup and trader payouts. The flow for a trader is depositing collateral -> betting directionally on token0 or token1 USD price -> profit/loss. In cases of loss, the proportionate margin gets donated as an LP fee (for renting liquidity). In cases of profit, the trader gets paid out in the fees LP earned or buffer capital (to be implemented), but ultimately for good design, there will need to be an implementation of how to take liquidity portions efficiently from LPs. Since nobody wants to rebalance 5000 positions, its been challenging to find a univ4 accounting trick to make this work. 
In pools like ETH/UNI, you bet on ETH/USD or UNI/USD, not on the ETH/UNI ratio (simply because I thought that traders tend to bet on USD denominated trades).

Since the betting is USD denominated and there is systematic risk on a pool like ETH/UNI which can drop 30% in value, the liquidity can become locked up until the trader cashes out. While the collateral a trader provides is in token0/token1, and so are its profits which would want to make them cash out, the risk is still real.

That’s why I am still keen on revamping the architecture to alleviate both of these problems as much as possible.


## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
