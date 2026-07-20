# XAUUSD-SMC-Algorithmic-Trader
This is a project still quite underdevelopment featuring an automated trading system designed for MT5 and currently focused on the Smart Money Concept for XAUUSD (Gold)

## Architecture
*   `python_prototype/`: Python engine used mainly for building and putting together the core ideas of the SMC together with other functions.
*   `XAU_SMC_Trader.mq5`: Production-ready Expert Advisor (EA) optimized for live execution and back testing inside the MetaTrader 5 terminal.

## Core Logic
The system evaluates the market through a dual-timeframe structural filter:
1.  **H1 Structural Bias**: Scans the last 100 hourly candles using an ATR-based filter to detect valid Bullish and Bearish Order Blocks (OB).
2.  **M5 Confirmation (CHoCH)**: Tracks micro-market structures inside the identified H1 Order Block. It confirms entries only when a Change of Character (CHoCH) occurs via an dynamic peak/trough detection algorithm.

## Risk & Position Management
*   **Dynamic Position Sizing**: Automatically calculates lot sizes for every trade based on a fixed account balance risk (e.g., 1.0%) and the current distance to the structural Stop Loss.
*   **R-Multiple Execution**: Management metrics are completely calculated in R-multiples (Risk Units) rather than fixed dollar points.
*   **Partial Closure**: Closes 66% of the position volume once the price reaches 1.0R profit to secure the trade.
*   **Trailing Stop**: Activates a trend-following trailing stop lagging 1.0R behind the current price to maximize runner performance while protecting capital.

## Cooldown & Overtrade Protections
*   **Session Guard**: Checks the active market trading sessions to prevent orders from being sent during market closures or weekend gaps.
*   **Loss Cooldown**: Limits maximum trades per day and enforces an H1 bar-based timeout period if a successive losing streak occurs.
*   **Zone Blacklisting**: Implements an ATR-padded zone memory buffer to prevent re-entering a failed Order Block immediately after a stop-out.
