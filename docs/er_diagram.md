# F&O Database - Entity Relationship Diagram

## ER Diagram (Mermaid Format)

```mermaid
erDiagram
    EXCHANGES ||--o{ INSTRUMENTS : lists
    INSTRUMENTS ||--o{ TRADES : has
    INSTRUMENTS ||--o{ EXPIRIES : defines
    EXPIRIES ||--o{ TRADES : governs
    
    EXCHANGES {
        int exchange_id PK
        varchar exchange_code UK "NSE, BSE, MCX"
        varchar exchange_name
        varchar country
        boolean is_active
        timestamp created_at
    }
    
    INSTRUMENTS {
        int instrument_id PK
        int exchange_id FK
        varchar instrument_type "FUTIDX, OPTIDX, FUTSTK, OPTSTK"
        varchar symbol "NIFTY, BANKNIFTY, GOLD, etc"
        varchar series "FUT, OPT"
        timestamp created_at
        unique(exchange_id, instrument_type, symbol)
    }
    
    EXPIRIES {
        int expiry_id PK
        int instrument_id FK
        date expiry_date
        decimal strike_price "0 for futures"
        varchar option_type "CE, PE, XX for futures"
        boolean is_active
        timestamp created_at
        unique(instrument_id, expiry_date, strike_price, option_type)
    }
    
    TRADES {
        bigint trade_id PK
        int expiry_id FK
        int instrument_id FK
        date trade_date
        decimal open
        decimal high
        decimal low
        decimal close
        decimal settle_price
        bigint contracts
        decimal value_in_lakh
        bigint open_interest
        bigint change_in_oi
        timestamp timestamp
        timestamp created_at
    }
```

## Normalization Justification (3NF)

### 1st Normal Form (1NF)
- All attributes contain atomic values
- No repeating groups or arrays
- Each column has a unique name

### 2nd Normal Form (2NF)
- All non-key attributes fully dependent on primary key
- Separated instrument metadata from trade data
- Removed partial dependencies

### 3rd Normal Form (3NF)
- No transitive dependencies
- Exchange details separated from instruments
- Expiry details (strike, option type) separated to eliminate redundancy
- Trade data references only expiry_id and instrument_id

## Entity Descriptions

### EXCHANGES
**Purpose**: Store exchange master data (NSE, BSE, MCX)
**Cardinality**: Low (< 10 records)
**Rationale**: Enables multi-exchange support, provides reference data

### INSTRUMENTS
**Purpose**: Unique instrument definitions per exchange
**Cardinality**: Medium (1000-5000 records)
**Rationale**: Eliminates symbol redundancy, supports cross-exchange analysis

### EXPIRIES
**Purpose**: Contract specifications with expiry dates and strikes
**Cardinality**: High (50K-100K records for 3 months)
**Rationale**: Reduces data duplication - stores strike/option_type once per contract

### TRADES
**Purpose**: Daily OHLC and volume data
**Cardinality**: Very High (2.5M+ records for 3 months)
**Rationale**: Optimized for time-series queries, partitioned by date

## Relationships

1. **EXCHANGES to INSTRUMENTS** (1:N)
   - One exchange lists many instruments
   - Supports cross-exchange comparison

2. **INSTRUMENTS to EXPIRIES** (1:N)
   - One instrument has many expiry contracts
   - Handles options chain efficiently

3. **EXPIRIES to TRADES** (1:N)
   - One contract generates many daily trades
   - Primary query path for analytics

4. **INSTRUMENTS to TRADES** (1:N)
   - Direct reference for instrument-level aggregations
   - Denormalized for query performance

## Design Decisions

### Why Not Star Schema?
- Star schema optimizes for OLAP with heavy denormalization
- Our use case needs normalized 3NF for:
  - Data integrity with ACID transactions
  - Real-time ingestion with minimal redundancy
  - Complex joins for multi-dimensional analysis
  - Future scalability to 10M+ rows without massive duplication

### Why Separate EXPIRIES Table?
- Option chains have 50-100 strikes per expiry
- Without separation: 2.5M trades × 3 columns = 7.5M redundant values
- With separation: ~100K expiry records, significant space savings
- Enables efficient option chain queries grouped by expiry

### Scalability for HFT (10M+ rows)
1. **Partitioning**: TRADES table by trade_date (monthly/quarterly)
2. **Indexing**: B-tree on (instrument_id, trade_date), BRIN on timestamp
3. **Archival**: Move old partitions to cold storage
4. **Read Replicas**: Separate analytics from ingestion workload
