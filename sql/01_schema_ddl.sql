-- ================================================================
-- F&O DATABASE - DDL SCRIPT (PostgreSQL)
-- Schema Design: 3NF Normalized for Multi-Exchange F&O Data
-- Target: NSE, BSE, MCX with 10M+ row scalability
-- ================================================================

-- Drop existing tables (in dependency order)
DROP TABLE IF EXISTS trades CASCADE;
DROP TABLE IF EXISTS expiries CASCADE;
DROP TABLE IF EXISTS instruments CASCADE;
DROP TABLE IF EXISTS exchanges CASCADE;

-- ================================================================
-- 1. EXCHANGES TABLE
-- ================================================================
CREATE TABLE exchanges (
    exchange_id SERIAL PRIMARY KEY,
    exchange_code VARCHAR(10) NOT NULL UNIQUE,  -- NSE, BSE, MCX
    exchange_name VARCHAR(100) NOT NULL,
    country VARCHAR(50) DEFAULT 'India',
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT chk_exchange_code CHECK (exchange_code IN ('NSE', 'BSE', 'MCX'))
);

-- Insert reference data
INSERT INTO exchanges (exchange_code, exchange_name) VALUES
    ('NSE', 'National Stock Exchange of India'),
    ('BSE', 'Bombay Stock Exchange'),
    ('MCX', 'Multi Commodity Exchange of India');

-- ================================================================
-- 2. INSTRUMENTS TABLE
-- ================================================================
CREATE TABLE instruments (
    instrument_id SERIAL PRIMARY KEY,
    exchange_id INT NOT NULL REFERENCES exchanges(exchange_id),
    instrument_type VARCHAR(10) NOT NULL,  -- FUTIDX, OPTIDX, FUTSTK, OPTSTK
    symbol VARCHAR(50) NOT NULL,           -- NIFTY, BANKNIFTY, GOLD, SENSEX
    series VARCHAR(10) NOT NULL,           -- FUT, OPT
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT uk_instrument UNIQUE(exchange_id, instrument_type, symbol),
    CONSTRAINT chk_instrument_type CHECK (instrument_type IN ('FUTIDX', 'OPTIDX', 'FUTSTK', 'OPTSTK')),
    CONSTRAINT chk_series CHECK (series IN ('FUT', 'OPT'))
);

-- Index for fast lookup by symbol across exchanges
CREATE INDEX idx_instruments_symbol ON instruments(symbol, exchange_id);
CREATE INDEX idx_instruments_type ON instruments(instrument_type);

-- ================================================================
-- 3. EXPIRIES TABLE (Contract Specifications)
-- ================================================================
CREATE TABLE expiries (
    expiry_id SERIAL PRIMARY KEY,
    instrument_id INT NOT NULL REFERENCES instruments(instrument_id),
    expiry_date DATE NOT NULL,
    strike_price DECIMAL(12, 2) NOT NULL DEFAULT 0,  -- 0 for futures
    option_type VARCHAR(2) NOT NULL DEFAULT 'XX',    -- CE, PE, XX (futures)
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT uk_expiry UNIQUE(instrument_id, expiry_date, strike_price, option_type),
    CONSTRAINT chk_option_type CHECK (option_type IN ('CE', 'PE', 'XX')),
    CONSTRAINT chk_strike_price CHECK (strike_price >= 0)
);

-- Indexes for option chain queries
CREATE INDEX idx_expiries_date ON expiries(expiry_date);
CREATE INDEX idx_expiries_instrument ON expiries(instrument_id, expiry_date);
CREATE INDEX idx_expiries_strike ON expiries(strike_price) WHERE option_type IN ('CE', 'PE');

-- ================================================================
-- 4. TRADES TABLE (Daily OHLC Data) - PARTITIONED
-- ================================================================
CREATE TABLE trades (
    trade_id BIGSERIAL,
    expiry_id INT NOT NULL REFERENCES expiries(expiry_id),
    instrument_id INT NOT NULL REFERENCES instruments(instrument_id),
    trade_date DATE NOT NULL,
    open DECIMAL(12, 2),
    high DECIMAL(12, 2),
    low DECIMAL(12, 2),
    close DECIMAL(12, 2),
    settle_price DECIMAL(12, 2),
    contracts BIGINT DEFAULT 0,
    value_in_lakh DECIMAL(15, 2) DEFAULT 0,
    open_interest BIGINT DEFAULT 0,
    change_in_oi BIGINT DEFAULT 0,
    timestamp TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (trade_id, trade_date),
    
    CONSTRAINT chk_ohlc CHECK (high >= low AND high >= open AND high >= close AND low <= open AND low <= close)
) PARTITION BY RANGE (trade_date);

-- Create partitions for 2019 data (Aug-Oct)
CREATE TABLE trades_2019_08 PARTITION OF trades
    FOR VALUES FROM ('2019-08-01') TO ('2019-09-01');

CREATE TABLE trades_2019_09 PARTITION OF trades
    FOR VALUES FROM ('2019-09-01') TO ('2019-10-01');

CREATE TABLE trades_2019_10 PARTITION OF trades
    FOR VALUES FROM ('2019-10-01') TO ('2019-11-01');

-- Future partitions (template for scalability)
CREATE TABLE trades_2019_11 PARTITION OF trades
    FOR VALUES FROM ('2019-11-01') TO ('2019-12-01');

-- ================================================================
-- PERFORMANCE INDEXES
-- ================================================================

-- Time-series queries (most common access pattern)
CREATE INDEX idx_trades_date ON trades(trade_date DESC);
CREATE INDEX idx_trades_timestamp ON trades(timestamp DESC) WITH (fillfactor = 90);

-- Instrument-based queries
CREATE INDEX idx_trades_instrument_date ON trades(instrument_id, trade_date DESC);
CREATE INDEX idx_trades_expiry_date ON trades(expiry_id, trade_date DESC);

-- Open Interest analysis
CREATE INDEX idx_trades_oi ON trades(open_interest DESC) WHERE open_interest > 0;

-- Volume analysis
CREATE INDEX idx_trades_volume ON trades(contracts DESC) WHERE contracts > 0;

-- Covering index for common SELECT columns
CREATE INDEX idx_trades_covering ON trades(instrument_id, trade_date, close, open_interest, contracts);

-- BRIN index for timestamp (efficient for sequential data)
CREATE INDEX idx_trades_timestamp_brin ON trades USING BRIN(timestamp) WITH (pages_per_range = 128);

-- ================================================================
-- MATERIALIZED VIEW FOR DAILY AGGREGATES (Performance Optimization)
-- ================================================================
CREATE MATERIALIZED VIEW mv_daily_instrument_summary AS
SELECT 
    i.instrument_id,
    i.symbol,
    e.exchange_code,
    t.trade_date,
    COUNT(*) as num_contracts,
    SUM(t.contracts) as total_volume,
    SUM(t.value_in_lakh) as total_value,
    AVG(t.close) as avg_close,
    MAX(t.high) as day_high,
    MIN(t.low) as day_low,
    SUM(t.open_interest) as total_oi,
    SUM(t.change_in_oi) as net_oi_change
FROM trades t
JOIN instruments i ON t.instrument_id = i.instrument_id
JOIN exchanges e ON i.exchange_id = e.exchange_id
GROUP BY i.instrument_id, i.symbol, e.exchange_code, t.trade_date;

CREATE UNIQUE INDEX idx_mv_daily_summary ON mv_daily_instrument_summary(instrument_id, trade_date);
CREATE INDEX idx_mv_daily_symbol ON mv_daily_instrument_summary(symbol, trade_date);

-- Refresh command (run after data load)
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_instrument_summary;

-- ================================================================
-- HELPER FUNCTIONS
-- ================================================================

-- Function to get option chain for a specific date
CREATE OR REPLACE FUNCTION get_option_chain(
    p_symbol VARCHAR,
    p_expiry_date DATE,
    p_trade_date DATE
)
RETURNS TABLE (
    strike_price DECIMAL,
    ce_close DECIMAL,
    ce_oi BIGINT,
    ce_volume BIGINT,
    pe_close DECIMAL,
    pe_oi BIGINT,
    pe_volume BIGINT
) AS $$
BEGIN
    RETURN QUERY
    WITH option_data AS (
        SELECT 
            ex.strike_price,
            ex.option_type,
            t.close,
            t.open_interest,
            t.contracts
        FROM trades t
        JOIN expiries ex ON t.expiry_id = ex.expiry_id
        JOIN instruments i ON t.instrument_id = i.instrument_id
        WHERE i.symbol = p_symbol
            AND ex.expiry_date = p_expiry_date
            AND t.trade_date = p_trade_date
            AND ex.option_type IN ('CE', 'PE')
    )
    SELECT 
        od.strike_price,
        MAX(CASE WHEN od.option_type = 'CE' THEN od.close END) as ce_close,
        MAX(CASE WHEN od.option_type = 'CE' THEN od.open_interest END) as ce_oi,
        MAX(CASE WHEN od.option_type = 'CE' THEN od.contracts END) as ce_volume,
        MAX(CASE WHEN od.option_type = 'PE' THEN od.close END) as pe_close,
        MAX(CASE WHEN od.option_type = 'PE' THEN od.open_interest END) as pe_oi,
        MAX(CASE WHEN od.option_type = 'PE' THEN od.contracts END) as pe_volume
    FROM option_data od
    GROUP BY od.strike_price
    ORDER BY od.strike_price;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- STATISTICS AND MAINTENANCE
-- ================================================================

-- Analyze tables for query optimizer
ANALYZE exchanges;
ANALYZE instruments;
ANALYZE expiries;
-- ANALYZE trades;  -- Run after data load

-- Display schema information
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
