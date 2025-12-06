-- QUERY 1: Top 10 Symbols by Open Interest Change Across Exchanges
-- Purpose: Identify instruments with highest trading interest momentum

WITH oi_changes AS (
    SELECT 
        i.symbol,
        e.exchange_code,
        i.instrument_type,
        t.trade_date,
        SUM(t.change_in_oi) as daily_oi_change,
        SUM(t.open_interest) as total_oi,
        SUM(t.contracts) as total_volume
    FROM trades t
    JOIN instruments i ON t.instrument_id = i.instrument_id
    JOIN exchanges e ON i.exchange_id = e.exchange_id
    WHERE t.trade_date >= CURRENT_DATE - INTERVAL '30 days'  -- Last 30 days
    GROUP BY i.symbol, e.exchange_code, i.instrument_type, t.trade_date
),
symbol_aggregates AS (
    SELECT 
        symbol,
        exchange_code,
        SUM(daily_oi_change) as net_oi_change,
        AVG(total_oi) as avg_open_interest,
        SUM(total_volume) as cumulative_volume,
        COUNT(DISTINCT trade_date) as trading_days
    FROM oi_changes
    GROUP BY symbol, exchange_code
)
SELECT 
    symbol,
    exchange_code,
    net_oi_change,
    ROUND(avg_open_interest, 0) as avg_open_interest,
    cumulative_volume,
    trading_days,
    ROUND(net_oi_change::NUMERIC / NULLIF(trading_days, 0), 0) as avg_daily_oi_change,
    ROUND((net_oi_change::NUMERIC / NULLIF(avg_open_interest, 0)) * 100, 2) as oi_change_pct
FROM symbol_aggregates
ORDER BY ABS(net_oi_change) DESC
LIMIT 10;

/*
Sample Output:
symbol      | exchange | net_oi_change | avg_open_interest | cumulative_volume | oi_change_pct
------------|----------|---------------|-------------------|-------------------|---------------
BANKNIFTY   | NSE      | 5,234,500     | 15,678,900        | 45,234,120        | 33.38%
NIFTY       | NSE      | 4,892,300     | 28,445,200        | 78,234,560        | 17.20%
*/


-- QUERY 2: Volatility Analysis - 7-Day Rolling Std Dev for NIFTY Options
-- Purpose: Measure price volatility for risk assessment

WITH daily_closes AS (
    SELECT 
        t.trade_date,
        ex.expiry_date,
        ex.strike_price,
        ex.option_type,
        AVG(t.close) as avg_close,
        SUM(t.contracts) as volume
    FROM trades t
    JOIN expiries ex ON t.expiry_id = ex.expiry_id
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE i.symbol = 'NIFTY'
        AND i.instrument_type = 'OPTIDX'
        AND ex.option_type IN ('CE', 'PE')
        AND t.trade_date >= '2019-08-01'
        AND t.trade_date <= '2019-10-31'
    GROUP BY t.trade_date, ex.expiry_date, ex.strike_price, ex.option_type
),
rolling_volatility AS (
    SELECT 
        trade_date,
        expiry_date,
        strike_price,
        option_type,
        avg_close,
        volume,
        STDDEV(avg_close) OVER (
            PARTITION BY expiry_date, strike_price, option_type 
            ORDER BY trade_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) as rolling_7day_stddev,
        AVG(avg_close) OVER (
            PARTITION BY expiry_date, strike_price, option_type 
            ORDER BY trade_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) as rolling_7day_avg,
        COUNT(*) OVER (
            PARTITION BY expiry_date, strike_price, option_type 
            ORDER BY trade_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) as window_days
    FROM daily_closes
)
SELECT 
    trade_date,
    expiry_date,
    strike_price,
    option_type,
    ROUND(avg_close, 2) as close_price,
    volume,
    ROUND(rolling_7day_avg, 2) as ma_7day,
    ROUND(rolling_7day_stddev, 2) as volatility_7day,
    ROUND((rolling_7day_stddev / NULLIF(rolling_7day_avg, 0)) * 100, 2) as coefficient_of_variation,
    window_days
FROM rolling_volatility
WHERE window_days = 7  -- Only complete 7-day windows
    AND volume > 100    -- Filter low-volume strikes
ORDER BY trade_date DESC, strike_price, option_type
LIMIT 50;

/*
Sample Output:
trade_date | expiry_date | strike_price | option_type | close_price | volatility_7day | coefficient_of_variation
-----------|-------------|--------------|-------------|-------------|-----------------|-------------------------
2019-10-31 | 2019-11-28  | 11800        | CE          | 156.50      | 23.45           | 15.67%
2019-10-31 | 2019-11-28  | 11800        | PE          | 189.75      | 28.92           | 17.23%
*/


-- QUERY 3: Cross-Exchange Comparison (NSE vs MCX Futures)
-- Purpose: Compare settlement prices across exchanges
-- Note: Using NSE data only

WITH exchange_settlements AS (
    SELECT 
        e.exchange_code,
        i.symbol,
        i.instrument_type,
        t.trade_date,
        AVG(t.settle_price) as avg_settle_price,
        SUM(t.contracts) as total_contracts,
        SUM(t.value_in_lakh) as total_value,
        AVG(t.open_interest) as avg_oi
    FROM trades t
    JOIN instruments i ON t.instrument_id = i.instrument_id
    JOIN exchanges e ON i.exchange_id = e.exchange_id
    WHERE i.instrument_type IN ('FUTIDX', 'FUTSTK')
        AND t.trade_date >= '2019-08-01'
    GROUP BY e.exchange_code, i.symbol, i.instrument_type, t.trade_date
),
price_comparison AS (
    SELECT 
        symbol,
        trade_date,
        MAX(CASE WHEN exchange_code = 'NSE' THEN avg_settle_price END) as nse_settle,
        MAX(CASE WHEN exchange_code = 'BSE' THEN avg_settle_price END) as bse_settle,
        MAX(CASE WHEN exchange_code = 'MCX' THEN avg_settle_price END) as mcx_settle,
        MAX(CASE WHEN exchange_code = 'NSE' THEN total_contracts END) as nse_volume,
        MAX(CASE WHEN exchange_code = 'BSE' THEN total_contracts END) as bse_volume,
        MAX(CASE WHEN exchange_code = 'MCX' THEN total_contracts END) as mcx_volume
    FROM exchange_settlements
    GROUP BY symbol, trade_date
)
SELECT 
    symbol,
    trade_date,
    ROUND(nse_settle, 2) as nse_settle_price,
    ROUND(bse_settle, 2) as bse_settle_price,
    ROUND(mcx_settle, 2) as mcx_settle_price,
    nse_volume,
    bse_volume,
    mcx_volume,
    ROUND(ABS(nse_settle - COALESCE(bse_settle, nse_settle)), 2) as nse_bse_spread,
    ROUND(((nse_settle - COALESCE(bse_settle, nse_settle)) / NULLIF(nse_settle, 0)) * 100, 2) as spread_pct
FROM price_comparison
WHERE nse_settle IS NOT NULL
ORDER BY trade_date DESC, symbol
LIMIT 30;

/*
Sample Output:
symbol    | trade_date | nse_settle_price | nse_volume | bse_volume | nse_bse_spread
----------|------------|------------------|------------|------------|----------------
NIFTY     | 2019-10-31 | 11,012.45        | 1,234,567  | 45,678     | 2.35
BANKNIFTY | 2019-10-31 | 28,456.80        | 456,789    | 12,345     | 5.60
*/


-- QUERY 4: Option Chain Summary - Grouped by Expiry and Strike
-- Purpose: Build option chain view for traders

WITH option_summary AS (
    SELECT 
        i.symbol,
        ex.expiry_date,
        ex.strike_price,
        ex.option_type,
        t.trade_date,
        SUM(t.contracts) as total_volume,
        AVG(t.close) as avg_close,
        MAX(t.high) as day_high,
        MIN(t.low) as day_low,
        SUM(t.open_interest) as total_oi,
        SUM(t.value_in_lakh) as total_value,
        -- Implied volume (proxy for liquidity)
        SUM(t.contracts * t.close) as implied_volume
    FROM trades t
    JOIN expiries ex ON t.expiry_id = ex.expiry_id
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE i.symbol IN ('NIFTY', 'BANKNIFTY')
        AND i.instrument_type = 'OPTIDX'
        AND t.trade_date = '2019-08-01'  -- Specific trading day
    GROUP BY i.symbol, ex.expiry_date, ex.strike_price, ex.option_type, t.trade_date
),
pivoted_chain AS (
    SELECT 
        symbol,
        expiry_date,
        strike_price,
        MAX(CASE WHEN option_type = 'CE' THEN avg_close END) as ce_close,
        MAX(CASE WHEN option_type = 'CE' THEN total_volume END) as ce_volume,
        MAX(CASE WHEN option_type = 'CE' THEN total_oi END) as ce_oi,
        MAX(CASE WHEN option_type = 'CE' THEN implied_volume END) as ce_implied_vol,
        MAX(CASE WHEN option_type = 'PE' THEN avg_close END) as pe_close,
        MAX(CASE WHEN option_type = 'PE' THEN total_volume END) as pe_volume,
        MAX(CASE WHEN option_type = 'PE' THEN total_oi END) as pe_oi,
        MAX(CASE WHEN option_type = 'PE' THEN implied_volume END) as pe_implied_vol
    FROM option_summary
    GROUP BY symbol, expiry_date, strike_price
)
SELECT 
    symbol,
    expiry_date,
    strike_price,
    ROUND(ce_close, 2) as call_price,
    ce_volume as call_volume,
    ce_oi as call_oi,
    ROUND(ce_implied_vol, 0) as call_implied_vol,
    ROUND(pe_close, 2) as put_price,
    pe_volume as put_volume,
    pe_oi as put_oi,
    ROUND(pe_implied_vol, 0) as put_implied_vol,
    -- Put-Call Ratio
    ROUND(pe_volume::NUMERIC / NULLIF(ce_volume, 0), 2) as pcr_volume,
    ROUND(pe_oi::NUMERIC / NULLIF(ce_oi, 0), 2) as pcr_oi
FROM pivoted_chain
WHERE ce_close IS NOT NULL OR pe_close IS NOT NULL
ORDER BY symbol, expiry_date, strike_price
LIMIT 50;

/*
Sample Output:
symbol    | expiry_date | strike_price | call_price | call_volume | call_oi | put_price | put_volume | put_oi | pcr_volume
----------|-------------|--------------|------------|-------------|---------|-----------|------------|--------|------------
NIFTY     | 2019-08-29  | 11000        | 245.60     | 12,345      | 234,567 | 156.80    | 15,678     | 345,678| 1.27
NIFTY     | 2019-08-29  | 11100        | 178.90     | 23,456      | 456,789 | 198.50    | 18,900     | 389,012| 0.81
*/


-- ================================================================
-- QUERY 5: Performance-Optimized Max Volume in Last 30 Days
-- Purpose: Identify high-liquidity trading opportunities

WITH ranked_volumes AS (
    SELECT 
        i.symbol,
        i.instrument_type,
        e.exchange_code,
        t.trade_date,
        SUM(t.contracts) as daily_volume,
        SUM(t.value_in_lakh) as daily_value,
        AVG(t.open_interest) as avg_oi,
        -- Rank by volume within each symbol
        ROW_NUMBER() OVER (
            PARTITION BY i.symbol, i.instrument_type 
            ORDER BY SUM(t.contracts) DESC
        ) as volume_rank
    FROM trades t
    JOIN instruments i ON t.instrument_id = i.instrument_id
    JOIN exchanges e ON i.exchange_id = e.exchange_id
    WHERE t.trade_date >= CURRENT_DATE - INTERVAL '30 days'
        AND t.contracts > 0
    GROUP BY i.symbol, i.instrument_type, e.exchange_code, t.trade_date
)
SELECT 
    symbol,
    instrument_type,
    exchange_code,
    trade_date,
    daily_volume,
    ROUND(daily_value, 2) as daily_value_lakh,
    ROUND(avg_oi, 0) as avg_open_interest,
    ROUND(daily_value / NULLIF(daily_volume, 0), 2) as avg_price_per_contract
FROM ranked_volumes
WHERE volume_rank <= 5  -- Top 5 volume days per symbol
ORDER BY daily_volume DESC
LIMIT 50;

/*
Sample Output:
symbol      | instrument_type | trade_date | daily_volume | daily_value_lakh | avg_open_interest
------------|-----------------|------------|--------------|------------------|-------------------
BANKNIFTY   | OPTIDX          | 2019-08-15 | 8,456,789    | 456,789.50       | 2,345,678
NIFTY       | OPTIDX          | 2019-08-22 | 7,234,567    | 389,456.75       | 3,456,789
*/


-- ================================================================
-- QUERY 6: Intraday Price Movement Analysis (High-Low Range)
-- Purpose: Identify volatile trading sessions

WITH price_movements AS (
    SELECT 
        i.symbol,
        i.instrument_type,
        t.trade_date,
        AVG(t.high) as avg_high,
        AVG(t.low) as avg_low,
        AVG(t.close) as avg_close,
        AVG(t.high - t.low) as avg_range,
        SUM(t.contracts) as total_volume,
        AVG((t.high - t.low) / NULLIF(t.low, 0) * 100) as avg_range_pct
    FROM trades t
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE t.trade_date >= '2019-08-01'
        AND t.trade_date <= '2019-10-31'
        AND t.high > 0 AND t.low > 0
    GROUP BY i.symbol, i.instrument_type, t.trade_date
)
SELECT 
    symbol,
    instrument_type,
    trade_date,
    ROUND(avg_high, 2) as avg_high,
    ROUND(avg_low, 2) as avg_low,
    ROUND(avg_close, 2) as avg_close,
    ROUND(avg_range, 2) as avg_range,
    ROUND(avg_range_pct, 2) as range_pct,
    total_volume,
    -- Volatility classification
    CASE 
        WHEN avg_range_pct > 5 THEN 'High Volatility'
        WHEN avg_range_pct > 2 THEN 'Medium Volatility'
        ELSE 'Low Volatility'
    END as volatility_class
FROM price_movements
WHERE avg_range_pct > 1  -- Filter noise
ORDER BY avg_range_pct DESC
LIMIT 30;

/*
Sample Output:
symbol      | trade_date | avg_range | range_pct | total_volume | volatility_class
------------|------------|-----------|-----------|--------------|------------------
BANKNIFTY   | 2019-08-05 | 456.80    | 6.78      | 1,234,567    | High Volatility
NIFTY       | 2019-08-05 | 178.90    | 4.23      | 2,345,678    | Medium Volatility
*/


-- ================================================================
-- QUERY 7: Most Active Options by Expiry Month
-- Purpose: Identify preferred expiry cycles for trading

WITH expiry_activity AS (
    SELECT 
        i.symbol,
        DATE_TRUNC('month', ex.expiry_date) as expiry_month,
        COUNT(DISTINCT ex.expiry_id) as num_contracts,
        SUM(t.contracts) as total_volume,
        SUM(t.value_in_lakh) as total_value,
        AVG(t.open_interest) as avg_oi,
        COUNT(DISTINCT t.trade_date) as trading_days
    FROM trades t
    JOIN expiries ex ON t.expiry_id = ex.expiry_id
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE i.instrument_type = 'OPTIDX'
        AND ex.option_type IN ('CE', 'PE')
    GROUP BY i.symbol, DATE_TRUNC('month', ex.expiry_date)
)
SELECT 
    symbol,
    TO_CHAR(expiry_month, 'YYYY-MM') as expiry_month,
    num_contracts,
    total_volume,
    ROUND(total_value, 2) as total_value_lakh,
    ROUND(avg_oi, 0) as avg_open_interest,
    trading_days,
    ROUND(total_volume::NUMERIC / NULLIF(trading_days, 0), 0) as avg_daily_volume,
    ROUND(total_value / NULLIF(total_volume, 0), 2) as avg_premium
FROM expiry_activity
ORDER BY total_volume DESC
LIMIT 20;

/*
Sample Output:
symbol      | expiry_month | num_contracts | total_volume | total_value_lakh | avg_daily_volume
------------|--------------|---------------|--------------|------------------|------------------
BANKNIFTY   | 2019-08      | 345           | 45,678,900   | 2,345,678.90     | 2,283,945
NIFTY       | 2019-08      | 456           | 78,901,234   | 3,456,789.12     | 3,945,062
*/
