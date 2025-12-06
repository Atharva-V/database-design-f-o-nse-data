"""
F&O Analytics Visualization Script
Generate charts and graphs from query results
"""

import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import duckdb
from pathlib import Path

# Set style
sns.set_style("whitegrid")
plt.rcParams['figure.figsize'] = (12, 6)

# Connect to database
conn = duckdb.connect('fo_analytics.duckdb')

# Output directory
output_dir = Path('results')
output_dir.mkdir(exist_ok=True)


def plot_oi_trends():
    """Plot Open Interest trends over time"""
    query = """
        SELECT 
            i.symbol,
            t.trade_date,
            SUM(t.open_interest) as total_oi
        FROM trades t
        JOIN instruments i ON t.instrument_id = i.instrument_id
        WHERE i.symbol IN ('NIFTY', 'BANKNIFTY')
        GROUP BY i.symbol, t.trade_date
        ORDER BY t.trade_date
    """
    
    df = conn.execute(query).fetchdf()
    
    plt.figure(figsize=(14, 7))
    for symbol in df['symbol'].unique():
        data = df[df['symbol'] == symbol]
        plt.plot(data['trade_date'], data['total_oi'], marker='o', label=symbol, linewidth=2)
    
    plt.title('Open Interest Trends - NIFTY vs BANKNIFTY', fontsize=16, fontweight='bold')
    plt.xlabel('Trade Date', fontsize=12)
    plt.ylabel('Total Open Interest', fontsize=12)
    plt.legend(fontsize=12)
    plt.xticks(rotation=45)
    plt.tight_layout()
    plt.savefig(output_dir / 'oi_trends.png', dpi=300)
    print("✅ Saved: oi_trends.png")


def plot_volume_distribution():
    """Plot volume distribution histogram"""
    query = """
        SELECT contracts as volume
        FROM trades
        WHERE contracts > 0
        LIMIT 100000
    """
    
    df = conn.execute(query).fetchdf()
    
    plt.figure(figsize=(12, 6))
    plt.hist(df['volume'], bins=50, edgecolor='black', alpha=0.7, color='steelblue')
    plt.title('Trading Volume Distribution', fontsize=16, fontweight='bold')
    plt.xlabel('Contracts Traded', fontsize=12)
    plt.ylabel('Frequency', fontsize=12)
    plt.yscale('log')  # Log scale for better visualization
    plt.tight_layout()
    plt.savefig(output_dir / 'volume_distribution.png', dpi=300)
    print("✅ Saved: volume_distribution.png")


def plot_volatility_heatmap():
    """Plot volatility heatmap by strike and date"""
    query = """
        WITH daily_volatility AS (
            SELECT 
                ex.strike_price,
                t.trade_date,
                STDDEV(t.close) as volatility
            FROM trades t
            JOIN expiries ex ON t.expiry_id = ex.expiry_id
            JOIN instruments i ON t.instrument_id = i.instrument_id
            WHERE i.symbol = 'NIFTY'
                AND ex.option_type = 'CE'
                AND ex.strike_price BETWEEN 10800 AND 11200
                AND t.trade_date >= '2019-08-01'
                AND t.trade_date <= '2019-08-15'
            GROUP BY ex.strike_price, t.trade_date
        )
        SELECT * FROM daily_volatility
        WHERE volatility IS NOT NULL
    """
    
    df = conn.execute(query).fetchdf()
    
    if len(df) > 0:
        pivot = df.pivot(index='strike_price', columns='trade_date', values='volatility')
        
        plt.figure(figsize=(14, 8))
        sns.heatmap(pivot, cmap='YlOrRd', annot=False, fmt='.1f', cbar_kws={'label': 'Volatility'})
        plt.title('NIFTY Call Options Volatility Heatmap', fontsize=16, fontweight='bold')
        plt.xlabel('Trade Date', fontsize=12)
        plt.ylabel('Strike Price', fontsize=12)
        plt.xticks(rotation=45)
        plt.tight_layout()
        plt.savefig(output_dir / 'volatility_heatmap.png', dpi=300)
        print("✅ Saved: volatility_heatmap.png")
    else:
        print("⚠️ No data for volatility heatmap")


def plot_option_chain():
    """Plot option chain (Call vs Put volumes)"""
    query = """
        SELECT 
            ex.strike_price,
            ex.option_type,
            SUM(t.contracts) as total_volume
        FROM trades t
        JOIN expiries ex ON t.expiry_id = ex.expiry_id
        JOIN instruments i ON t.instrument_id = i.instrument_id
        WHERE i.symbol = 'NIFTY'
            AND ex.expiry_date = '2019-08-29'
            AND t.trade_date = '2019-08-01'
            AND ex.option_type IN ('CE', 'PE')
        GROUP BY ex.strike_price, ex.option_type
        ORDER BY ex.strike_price
    """
    
    df = conn.execute(query).fetchdf()
    
    if len(df) > 0:
        pivot = df.pivot(index='strike_price', columns='option_type', values='total_volume').fillna(0)
        
        fig, ax = plt.subplots(figsize=(14, 7))
        x = range(len(pivot))
        width = 0.35
        
        if 'CE' in pivot.columns:
            ax.bar([i - width/2 for i in x], pivot['CE'], width, label='Call (CE)', color='green', alpha=0.7)
        if 'PE' in pivot.columns:
            ax.bar([i + width/2 for i in x], pivot['PE'], width, label='Put (PE)', color='red', alpha=0.7)
        
        ax.set_xlabel('Strike Price', fontsize=12)
        ax.set_ylabel('Total Volume', fontsize=12)
        ax.set_title('NIFTY Option Chain - Call vs Put Volumes (Aug 29, 2019)', fontsize=16, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels(pivot.index, rotation=45)
        ax.legend(fontsize=12)
        plt.tight_layout()
        plt.savefig(output_dir / 'option_chain_visualization.png', dpi=300)
        print("✅ Saved: option_chain_visualization.png")
    else:
        print("⚠️ No data for option chain")


def main():
    """Generate all visualizations"""
    print("🎨 Generating visualizations...\n")
    
    try:
        plot_oi_trends()
        plot_volume_distribution()
        plot_volatility_heatmap()
        plot_option_chain()
        
        print("\n✅ All visualizations generated successfully!")
        print(f"📁 Output directory: {output_dir.absolute()}")
        
    except Exception as e:
        print(f"❌ Error: {e}")
    
    finally:
        conn.close()


if __name__ == "__main__":
    main()
