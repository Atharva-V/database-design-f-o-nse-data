"""
F&O Database Analytics - DuckDB Version (Alternative)
Faster loading and querying for analytical workloads
Suitable for local development and testing
"""

import duckdb
import pandas as pd
from pathlib import Path
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DATA_FILE = 'NSE_data_3M.csv'
DB_FILE = 'fo_analytics.duckdb'


def create_duckdb_schema(conn):
    """Create database schema in DuckDB"""
    
    # Create tables
    conn.execute("""
        CREATE TABLE IF NOT EXISTS exchanges (
            exchange_id INTEGER PRIMARY KEY,
            exchange_code VARCHAR UNIQUE,
            exchange_name VARCHAR,
            country VARCHAR DEFAULT 'India',
            is_active BOOLEAN DEFAULT true
        )
    """)
    
    conn.execute("""
        INSERT INTO exchanges VALUES
            (1, 'NSE', 'National Stock Exchange of India', 'India', true),
            (2, 'BSE', 'Bombay Stock Exchange', 'India', true),
            (3, 'MCX', 'Multi Commodity Exchange of India', 'India', true)
        ON CONFLICT DO NOTHING
    """)
    
    conn.execute("""
        CREATE TABLE IF NOT EXISTS instruments (
            instrument_id INTEGER PRIMARY KEY,
            exchange_id INTEGER,
            instrument_type VARCHAR,
            symbol VARCHAR,
            series VARCHAR,
            UNIQUE(exchange_id, instrument_type, symbol)
        )
    """)
    
    conn.execute("""
        CREATE TABLE IF NOT EXISTS expiries (
            expiry_id INTEGER PRIMARY KEY,
            instrument_id INTEGER,
            expiry_date DATE,
            strike_price DECIMAL(12, 2),
            option_type VARCHAR,
            UNIQUE(instrument_id, expiry_date, strike_price, option_type)
        )
    """)
    
    conn.execute("""
        CREATE TABLE IF NOT EXISTS trades (
            trade_id INTEGER PRIMARY KEY,
            expiry_id INTEGER,
            instrument_id INTEGER,
            trade_date DATE,
            open DECIMAL(12, 2),
            high DECIMAL(12, 2),
            low DECIMAL(12, 2),
            close DECIMAL(12, 2),
            settle_price DECIMAL(12, 2),
            contracts BIGINT,
            value_in_lakh DECIMAL(15, 2),
            open_interest BIGINT,
            change_in_oi BIGINT,
            timestamp TIMESTAMP
        )
    """)
    
    logger.info("Schema created successfully")


def load_data_duckdb(conn):
    """Load data directly from CSV using DuckDB's efficient CSV reader"""
    
    logger.info("Loading CSV data...")
    
    # Read CSV with column transformations
    conn.execute("""
        CREATE TEMP TABLE raw_data AS
        SELECT 
            INSTRUMENT as instrument,
            SYMBOL as symbol,
            TRY_CAST(strptime(EXPIRY_DT, '%d-%b-%Y') AS DATE) as expiry_dt,
            TRY_CAST(STRIKE_PR AS DECIMAL(12,2)) as strike_pr,
            OPTION_TYP as option_typ,
            TRY_CAST(OPEN AS DECIMAL(12,2)) as open,
            TRY_CAST(HIGH AS DECIMAL(12,2)) as high,
            TRY_CAST(LOW AS DECIMAL(12,2)) as low,
            TRY_CAST(CLOSE AS DECIMAL(12,2)) as close,
            TRY_CAST(SETTLE_PR AS DECIMAL(12,2)) as settle_pr,
            TRY_CAST(CONTRACTS AS BIGINT) as contracts,
            TRY_CAST(VAL_INLAKH AS DECIMAL(15,2)) as val_inlakh,
            TRY_CAST(OPEN_INT AS BIGINT) as open_int,
            TRY_CAST(CHG_IN_OI AS BIGINT) as chg_in_oi,
            TRY_CAST(strptime(TIMESTAMP, '%d-%b-%Y') AS TIMESTAMP) as timestamp
        FROM read_csv_auto(?, header=true, ignore_errors=true, sample_size=100000)
    """, [DATA_FILE])
    
    logger.info("Inserting instruments...")
    conn.execute("""
        INSERT INTO instruments
        SELECT 
            ROW_NUMBER() OVER () as instrument_id,
            1 as exchange_id,  -- NSE
            instrument,
            symbol,
            CASE WHEN instrument LIKE '%OPT%' THEN 'OPT' ELSE 'FUT' END as series
        FROM (
            SELECT DISTINCT instrument, symbol
            FROM raw_data
        )
        ON CONFLICT DO NOTHING
    """)
    
    logger.info("Inserting expiries...")
    conn.execute("""
        INSERT INTO expiries
        SELECT 
            ROW_NUMBER() OVER () as expiry_id,
            i.instrument_id,
            r.expiry_dt,
            COALESCE(r.strike_pr, 0) as strike_price,
            COALESCE(r.option_typ, 'XX') as option_type
        FROM (
            SELECT DISTINCT 
                instrument, symbol, expiry_dt, strike_pr, option_typ
            FROM raw_data
            WHERE expiry_dt IS NOT NULL
        ) r
        JOIN instruments i ON r.instrument = i.instrument_type 
            AND r.symbol = i.symbol
        ON CONFLICT DO NOTHING
    """)
    
    logger.info("Inserting trades...")
    conn.execute("""
        INSERT INTO trades
        SELECT 
            ROW_NUMBER() OVER () as trade_id,
            ex.expiry_id,
            i.instrument_id,
            CAST(r.timestamp AS DATE) as trade_date,
            COALESCE(r.open, 0),
            COALESCE(r.high, 0),
            COALESCE(r.low, 0),
            COALESCE(r.close, 0),
            COALESCE(r.settle_pr, 0),
            COALESCE(r.contracts, 0),
            COALESCE(r.val_inlakh, 0),
            COALESCE(r.open_int, 0),
            COALESCE(r.chg_in_oi, 0),
            r.timestamp
        FROM raw_data r
        JOIN instruments i ON r.instrument = i.instrument_type 
            AND r.symbol = i.symbol
        JOIN expiries ex ON ex.instrument_id = i.instrument_id
            AND ex.expiry_date = r.expiry_dt
            AND COALESCE(ex.strike_price, 0) = COALESCE(r.strike_pr, 0)
            AND COALESCE(ex.option_type, 'XX') = COALESCE(r.option_typ, 'XX')
        WHERE r.timestamp IS NOT NULL
    """)
    
    # Create indexes
    logger.info("Creating indexes...")
    conn.execute("CREATE INDEX idx_trades_instrument ON trades(instrument_id)")
    conn.execute("CREATE INDEX idx_trades_date ON trades(trade_date)")
    conn.execute("CREATE INDEX idx_trades_symbol_date ON trades(instrument_id, trade_date)")
    
    # Get statistics
    result = conn.execute("SELECT COUNT(*) FROM trades").fetchone()
    logger.info(f"Loaded {result[0]:,} trade records")
    
    result = conn.execute("SELECT COUNT(*) FROM instruments").fetchone()
    logger.info(f"Loaded {result[0]:,} instruments")
    
    result = conn.execute("SELECT COUNT(*) FROM expiries").fetchone()
    logger.info(f"Loaded {result[0]:,} expiry contracts")


def main():
    """Main execution"""
    try:
        # Connect to DuckDB
        conn = duckdb.connect(DB_FILE)
        logger.info(f"Connected to DuckDB: {DB_FILE}")
        
        # Create schema
        create_duckdb_schema(conn)
        
        # Load data
        load_data_duckdb(conn)
        
        logger.info("Data loading complete!")
        
        # Close connection
        conn.close()
        
    except Exception as e:
        logger.error(f"Error: {e}")
        raise


if __name__ == "__main__":
    main()
