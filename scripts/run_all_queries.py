"""
Execute all 7 analytical queries and save outputs
F&O Database Analytics - Query Results
"""
import duckdb
import pandas as pd
from datetime import datetime

# Connect to database
conn = duckdb.connect('fo_analytics.duckdb')

# Create results directory
import os
os.makedirs('query_outputs', exist_ok=True)

print("=" * 100)
print("F&O DATABASE ANALYTICS - RUNNING ALL 7 QUERIES")
print("=" * 100)

# ============================================================================
# QUERY 1: Top 10 Symbols by OI Change
# ============================================================================
print("\n[1/7] QUERY 1: Top 10 Symbols by OI Change")
print("-" * 100)

query1 = """
SELECT 
    i.symbol,
    e.exchange_code,
    SUM(t.change_in_oi) as net_oi_change,
    ROUND(AVG(t.open_interest), 0) as avg_open_interest,
    SUM(t.contracts) as cumulative_volume,
    COUNT(DISTINCT t.trade_date) as trading_days
FROM trades t
JOIN instruments i ON t.instrument_id = i.instrument_id
JOIN exchanges e ON i.exchange_id = e.exchange_id
WHERE t.trade_date >= '2019-08-01'
GROUP BY i.symbol, e.exchange_code
ORDER BY ABS(net_oi_change) DESC
LIMIT 10
"""

df1 = conn.execute(query1).fetchdf()
print(df1.to_string(index=False))
df1.to_csv('query_outputs/query1_oi_change.csv', index=False)
print("\nSaved: query_outputs/query1_oi_change.csv")

# QUERY 2: 7-Day Volatility Analysis
print("\n[2/7] QUERY 2: 7-Day Rolling Volatility for Top Symbols")
print("-" * 100)

query2 = """
WITH daily_closes AS (
    SELECT 
        i.symbol,
        t.trade_date,
        AVG(t.close) as avg_close
    FROM trades t
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE t.trade_date >= '2019-08-01'
    GROUP BY i.symbol, t.trade_date
),
rolling_volatility AS (
    SELECT 
        symbol,
        trade_date,
        avg_close,
        STDDEV(avg_close) OVER (
            PARTITION BY symbol 
            ORDER BY trade_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) as rolling_7day_stddev
    FROM daily_closes
)
SELECT 
    symbol,
    MAX(trade_date) as latest_date,
    ROUND(AVG(avg_close), 2) as avg_price,
    ROUND(AVG(rolling_7day_stddev), 2) as avg_volatility,
    ROUND(MIN(rolling_7day_stddev), 2) as min_volatility,
    ROUND(MAX(rolling_7day_stddev), 2) as max_volatility
FROM rolling_volatility
WHERE rolling_7day_stddev IS NOT NULL
GROUP BY symbol
ORDER BY avg_volatility DESC
LIMIT 10
"""

df2 = conn.execute(query2).fetchdf()
print(df2.to_string(index=False))
df2.to_csv('query_outputs/query2_volatility.csv', index=False)
print("\nSaved: query_outputs/query2_volatility.csv")

# QUERY 3: Cross-Exchange Comparison
print("\n[3/7] QUERY 3: Cross-Exchange Volume Comparison")
print("-" * 100)

query3 = """
SELECT 
    e.exchange_code,
    i.instrument_type,
    COUNT(DISTINCT i.symbol) as unique_symbols,
    SUM(t.contracts) as total_volume,
    ROUND(SUM(t.value_in_lakh), 2) as total_value_lakh,
    ROUND(AVG(t.close), 2) as avg_settlement_price
FROM trades t
JOIN instruments i ON t.instrument_id = i.instrument_id
JOIN exchanges e ON i.exchange_id = e.exchange_id
GROUP BY e.exchange_code, i.instrument_type
ORDER BY total_volume DESC
"""

df3 = conn.execute(query3).fetchdf()
print(df3.to_string(index=False))
df3.to_csv('query_outputs/query3_cross_exchange.csv', index=False)
print("\nSaved: query_outputs/query3_cross_exchange.csv")

# QUERY 4: Option Chain Summary
print("\n[4/7] QUERY 4: NIFTY Option Chain Summary")
print("-" * 100)

query4 = """
WITH option_summary AS (
    SELECT 
        ex.expiry_date,
        ex.strike_price,
        ex.option_type,
        SUM(t.contracts) as total_volume,
        SUM(t.open_interest) as total_oi,
        ROUND(AVG(t.close), 2) as avg_premium
    FROM trades t
    JOIN expiries ex ON t.expiry_id = ex.expiry_id
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE i.symbol = 'NIFTY'
        AND ex.option_type IN ('CE', 'PE')
        AND ex.expiry_date = (
            SELECT MIN(expiry_date) 
            FROM expiries 
            WHERE expiry_date >= '2019-09-26'
        )
    GROUP BY ex.expiry_date, ex.strike_price, ex.option_type
)
SELECT 
    expiry_date,
    strike_price,
    MAX(CASE WHEN option_type = 'CE' THEN total_volume ELSE 0 END) as CE_volume,
    MAX(CASE WHEN option_type = 'PE' THEN total_volume ELSE 0 END) as PE_volume,
    MAX(CASE WHEN option_type = 'CE' THEN total_oi ELSE 0 END) as CE_oi,
    MAX(CASE WHEN option_type = 'PE' THEN total_oi ELSE 0 END) as PE_oi,
    MAX(CASE WHEN option_type = 'CE' THEN avg_premium ELSE 0 END) as CE_premium,
    MAX(CASE WHEN option_type = 'PE' THEN avg_premium ELSE 0 END) as PE_premium
FROM option_summary
GROUP BY expiry_date, strike_price
ORDER BY strike_price
LIMIT 15
"""

df4 = conn.execute(query4).fetchdf()
print(df4.to_string(index=False))
df4.to_csv('query_outputs/query4_option_chain.csv', index=False)
print("\nSaved: query_outputs/query4_option_chain.csv")

# QUERY 5: Max Volume (Performance Optimized)
print("\n[5/7] QUERY 5: Highest Volume Trading Days (Optimized)")
print("-" * 100)

query5 = """
WITH ranked_volume AS (
    SELECT 
        i.symbol,
        t.trade_date,
        SUM(t.contracts) as daily_volume,
        ROW_NUMBER() OVER (PARTITION BY i.symbol ORDER BY SUM(t.contracts) DESC) as rank
    FROM trades t
    JOIN instruments i ON t.instrument_id = i.instrument_id
    WHERE t.contracts > 0
    GROUP BY i.symbol, t.trade_date
)
SELECT 
    symbol,
    trade_date,
    daily_volume
FROM ranked_volume
WHERE rank = 1
ORDER BY daily_volume DESC
LIMIT 10
"""

df5 = conn.execute(query5).fetchdf()
print(df5.to_string(index=False))
df5.to_csv('query_outputs/query5_max_volume.csv', index=False)
print("\nSaved: query_outputs/query5_max_volume.csv")

# QUERY 6: Intraday Price Movement
print("\n[6/7] QUERY 6: Intraday Price Movement Analysis")
print("-" * 100)

query6 = """
SELECT 
    i.symbol,
    t.trade_date,
    ROUND(AVG(t.high - t.low), 2) as avg_range,
    ROUND(AVG((t.high - t.low) / NULLIF(t.close, 0) * 100), 2) as avg_range_pct,
    ROUND(MAX(t.high - t.low), 2) as max_range,
    COUNT(*) as num_contracts
FROM trades t
JOIN instruments i ON t.instrument_id = i.instrument_id
WHERE (t.high - t.low) > 0
    AND t.close > 0
GROUP BY i.symbol, t.trade_date
HAVING avg_range_pct > 5
ORDER BY avg_range_pct DESC
LIMIT 10
"""

df6 = conn.execute(query6).fetchdf()
print(df6.to_string(index=False))
df6.to_csv('query_outputs/query6_price_movement.csv', index=False)
print("\nSaved: query_outputs/query6_price_movement.csv")

# ============================================================================
# QUERY 7: Most Active Options by Expiry
print("\n[7/7] QUERY 7: Most Active Options by Expiry Month")
print("-" * 100)

query7 = """
SELECT 
    i.symbol,
    ex.expiry_date,
    COUNT(DISTINCT ex.strike_price) as num_strikes,
    SUM(t.contracts) as total_volume,
    ROUND(SUM(t.value_in_lakh), 2) as total_value_lakh,
    ROUND(AVG(t.open_interest), 0) as avg_oi
FROM trades t
JOIN expiries ex ON t.expiry_id = ex.expiry_id
JOIN instruments i ON t.instrument_id = i.instrument_id
WHERE ex.option_type IN ('CE', 'PE')
GROUP BY i.symbol, ex.expiry_date
ORDER BY total_volume DESC
LIMIT 15
"""

df7 = conn.execute(query7).fetchdf()
print(df7.to_string(index=False))
df7.to_csv('query_outputs/query7_active_expiries.csv', index=False)
print("\nSaved: query_outputs/query7_active_expiries.csv")

# ============================================================================
# Summary Statistics
print("\n" + "=" * 100)
print("DATABASE STATISTICS")
print("=" * 100)

stats = conn.execute("""
SELECT 
    'Total Trades' as metric, 
    FORMAT('{:,}', COUNT(*)) as value 
FROM trades
UNION ALL
SELECT 'Total Instruments', FORMAT('{:,}', COUNT(*)) FROM instruments
UNION ALL
SELECT 'Total Expiries', FORMAT('{:,}', COUNT(*)) FROM expiries
UNION ALL
SELECT 'Total Exchanges', FORMAT('{:,}', COUNT(*)) FROM exchanges
UNION ALL
SELECT 'Date Range', 
    MIN(trade_date)::VARCHAR || ' to ' || MAX(trade_date)::VARCHAR 
FROM trades
UNION ALL
SELECT 'Total Volume (Contracts)', FORMAT('{:,}', SUM(contracts)::BIGINT) FROM trades
UNION ALL
SELECT 'Total Value (Lakh)', FORMAT('{:,.2f}', SUM(value_in_lakh)) FROM trades
""").fetchdf()

print(stats.to_string(index=False))

conn.close()

print("\n" + "=" * 100)
print("ALL 7 QUERIES EXECUTED SUCCESSFULLY!")
print("Results saved in: query_outputs/")
print("=" * 100)
