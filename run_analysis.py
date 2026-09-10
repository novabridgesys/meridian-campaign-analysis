#!/usr/bin/env python3
"""
run_analysis.py

Executes the full SQL pipeline against DuckDB and prints the analysis outputs.
Also regenerates the Power BI star schema exports.

Usage:
    pip install duckdb pandas
    python run_analysis.py

Run from the project root so the relative paths in the SQL resolve.
"""

import sys
from pathlib import Path

try:
    import duckdb
    import pandas as pd
except ImportError:
    sys.exit("Missing dependencies. Run: pip install duckdb pandas")

PROJECT_ROOT = Path(__file__).parent
SQL_FILES = [
    "sql/01_staging.sql",
    "sql/02_performance_analysis.sql",
    "sql/03_export_powerbi.sql",
    "sql/04_advanced_analysis.sql",
]

# Expected values, asserted after the pipeline runs. These are the reconciliation
# figures that must match the Excel workbook. Hardcoding them here turns a silent
# data drift into a loud failure.
EXPECTED = {
    "leads": 534,
    "conversions": 67,
    "total_cost": 12835.30,
    "total_revenue": 8793.00,
}

REPORTS = [
    ("Data quality audit",              "audit_data_quality"),
    ("Performance by channel",          "performance_by_channel"),
    ("Performance by vertical",         "performance_by_vertical"),
    ("Performance by advertiser",       "performance_by_advertiser"),
    ("Statistical confidence",          "advertiser_confidence"),
    ("Weekly trend",                    "weekly_trend"),
    ("Performance by state",            "performance_by_state"),
    ("Reallocation scenario",           "reallocation_scenario"),
    ("Lead aging",                      "lead_aging"),
    ("Attribution censoring",           "attribution_censoring"),
    ("Cost / quality frontier",         "cost_quality_frontier"),
    ("Performance by region",           "performance_by_region"),
    ("Sensitivity grid",                "sensitivity_grid"),
]


def main() -> int:
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 40)

    con = duckdb.connect()

    for sql_file in SQL_FILES:
        path = PROJECT_ROOT / sql_file
        if not path.exists():
            sys.exit(f"Missing SQL file: {sql_file}")
        con.execute(path.read_text())
        print(f"  executed {sql_file}")

    # Reconciliation gate. Fail loudly before printing anything that looks
    # authoritative, rather than after.
    actual = con.execute("""
        SELECT COUNT(*)                       AS leads,
               SUM(is_converted)              AS conversions,
               ROUND(SUM(acquisition_cost),2) AS total_cost,
               SUM(commission_revenue)        AS total_revenue
        FROM fct_leads
    """).fetchone()

    checks = dict(zip(["leads", "conversions", "total_cost", "total_revenue"], actual))
    failures = [
        f"{k}: expected {v}, got {checks[k]}"
        for k, v in EXPECTED.items()
        if abs(float(checks[k]) - float(v)) > 0.01
    ]
    if failures:
        print("\nRECONCILIATION FAILED")
        for f in failures:
            print(f"  {f}")
        return 1

    print(f"\nReconciliation passed: {checks['leads']} leads, "
          f"{checks['conversions']} conversions, "
          f"${checks['total_cost']:,.2f} spend, "
          f"${checks['total_revenue']:,.2f} revenue\n")

    for title, view in REPORTS:
        print("=" * 78)
        print(title.upper())
        print("=" * 78)
        print(con.execute(f"SELECT * FROM {view}").df().to_string(index=False))
        print()

    print("Power BI exports written to powerbi/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
