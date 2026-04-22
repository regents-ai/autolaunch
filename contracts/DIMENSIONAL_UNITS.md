# Base Units
- `{tok}`: Any ERC20 amount or supply in the launch, staking, reward, or fee flows. Use for balances, allowances, minted amounts, total supply, and transfers.
- `{UoA}`: Unit of account for value-denominated flows, centered on USDC in this workspace.
- `{liq}`: Uniswap liquidity minted or migrated into a position.
- `{s}`: Seconds for timestamps and durations.
- `{block}`: Block height used for launch phase gates and migration timing.
- `{1}`: Dimensionless values such as ratios, percentages, counters, and other unitless scalars.

# Derived Units
- `{UoA/tok}`: Price or quote per token, including floor prices, swap quotes, and revenue-per-token values.
- `{tok/UoA}`: Inverse price, or tokens per unit of account.
- `Q96{sqrt(UoA/tok)}`: Uniswap sqrt-price used when initializing pools and computing pool state.
- `D27{UoA/tok}`: High-precision per-token value accumulator for USDC revenue accounting.
- `D27{tok/tok}`: High-precision per-token accumulator for same-token emission and reward accounting.
- `{tok/s}`: Token amount streamed over time, useful for vesting and emission rates.
- `D7{1}`: 1e7-scaled allocation ratio used by `tokenSplitToAuctionMps`.

# Precision Prefixes
- `D4`: Basis-point precision, used for fee and allocation ratios such as `emissionAprBps` and `lpCurrencyBps`.
- `D6`: 1e6-scaled precision, used for Uniswap-style pool fees and fee caps.
- `D7`: 1e7-scaled precision, used for the auction split scalar in `tokenSplitToAuctionMps`.
- `D18`: Standard ERC20 and fixed-point precision, common for launch-token math and 18-decimal values.
- `D27`: High-precision accumulator scale for reward and price math.
- `Q96`: Uniswap sqrt-price precision used for square-root pool pricing.
