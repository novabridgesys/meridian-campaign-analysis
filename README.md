# Recovering Margin in a Leaking Lead Marketplace

A campaign profitability analysis across 8 advertisers, 5 acquisition channels,
and 534 synthetic leads, built in SQL, Power BI, Excel, and Python.

**Read the analysis: [CASE_STUDY.md](CASE_STUDY.md)**

---

## Headline findings

| | |
|---|---|
| Portfolio | **-$4,042** monthly net, **-31.5%** ROI |
| Concentration | Two of five verticals account for **83%** of the loss |
| Recoverable | Wider cut + redeploy: **$4,300–$6,100** monthly contribution |
| Withdrawn | Two advertiser offboarding calls fail Wilson confidence tests |
| Survives | Affiliate vs Display intervals do not overlap; channel reallocation stands |

Data is synthetic. No proprietary, client, or consumer data is used.

---

## SQL and Power BI layer

The original version of this analysis was built in Excel. This layer reimplements it in SQL and models it for Power BI. The business findings are unchanged and every figure reconciles to the workbook; what changes is that the logic is now version-controlled, re-runnable, and portable to a warehouse.

---

## Running it

```bash
pip install duckdb pandas matplotlib scipy
python run_analysis.py    # asserts reconciliation, prints every view
python make_charts.py     # regenerates every figure
```

DuckDB runs in-process with no server, so the pipeline executes directly against the CSVs. The script fails loudly if the outputs stop reconciling to the expected totals rather than printing numbers that look authoritative but have drifted.

---

## Structure

```
sql/
  01_staging.sql              Deduplication, null resolution, enrichment, DQ audit
  02_performance_analysis.sql Analysis at advertiser / vertical / channel / state
                              grain, statistical confidence, scenario model
  03_export_powerbi.sql       Star schema materialisation for the semantic model
  04_advanced_analysis.sql    Lead aging, attribution censoring, cost/quality
                              frontier, regional rollup, 2D sensitivity grid
powerbi/
  fct_leads.csv               Fact table (534 rows)
  dim_campaign.csv            Campaign dimension (13 rows)
  dim_date.csv                Date dimension (31 rows)
  dim_state.csv               Geography dimension (12 rows)
  measures.dax                25 DAX measures
  BUILD_GUIDE.md              Model setup, relationships, report pages
assets/                       Figures, generated from the SQL views
run_analysis.py               Pipeline runner with a reconciliation gate
make_charts.py                Figure generation
CASE_STUDY.md                 The written case study
DATA_DICTIONARY.md            Schema, metric definitions, known limitations
```

---

## What changed from the Excel version

### Deduplication

Excel flagged duplicates with a running `COUNTIF` against the rows above. That works, but it depends on row order and breaks if the sheet is re-sorted. The SQL version uses `ROW_NUMBER()` partitioned on the business key with an explicit `ORDER BY`, which makes "which duplicate survives" a stated decision rather than a side effect of scan order.

### Null handling

Unchanged in substance: a null acquisition cost is resolved to the campaign's contracted rate rather than dropped or zeroed, because both of those silently understate spend. The addition is an `is_cost_imputed` flag carried through to the fact table, so imputed rows can be isolated downstream. An imputed value that cannot be identified downstream is indistinguishable from a measured one.

### Analysis

`SUMIFS` and `COUNTIFS` cross-tabs become `GROUP BY` with window functions. Share-of-total columns that were division against a grand-total cell in Excel become `SUM(...) OVER ()`. Week-over-week deltas that were manual previous-cell references become `LAG`. Every denominator is wrapped in `NULLIF` so a zero-conversion segment returns null rather than raising an error.

### Statistical confidence, which is new

This is the substantive correction, not a port. The Excel version reported conversion rates as point estimates and drew conclusions from them at segment sizes as small as 28 leads with one conversion. `advertiser_confidence` adds Wilson score intervals and classifies each segment by whether its evidence is strong enough to act on.

The result overturned two of the original recommendations. Guardian Life Partners, previously flagged for offboarding, has a 95% interval spanning 0.6% to 17.7%, which is compatible with it being an average performer. Coastal P&C Partners is likewise unresolvable at n=39.

What survives: Affiliate at [14.5%, 32.4%] and Display at [2.7%, 13.8%] do not overlap, so the channel reallocation, which is the recommendation carrying most of the projected value, stands on firm ground.

The classification uses the conventional minimum of five observed successes rather than interval width alone, because a segment with a single conversion produces a deceptively narrow interval simply by sitting near zero.

One scoping note that matters: the confidence classification governs conclusions about conversion *rate*. Cost-side conclusions are independent of it. Everwell Life is flagged insufficient for rate inference, yet its economic case is still decisive, because a $1,012 CPA against a $190 commission cannot break even at any conversion rate inside its own interval.

### Scenario model, which is also new

The Excel version presented a single reallocation projection. `reallocation_scenario` parameterises the efficiency-decay assumption across three haircuts, so the sensitivity of the conclusion is visible rather than buried in a footnote.

| Scenario | Projected monthly net | Monthly swing | Annualised |
|---|---|---|---|
| Baseline (actual) | -$4,042 | | |
| Conservative (50% of benchmark) | -$179 | +$3,863 | ~$46,400 |
| Moderate (75% of benchmark) | +$247 | +$4,289 | ~$51,500 |
| Full benchmark | +$673 | +$4,716 | ~$56,600 |

---

## Portability

Written for DuckDB, but deliberately close to ANSI. Porting to BigQuery or Snowflake requires changing the source table definitions (`read_csv_auto` to real tables), swapping `ANY_VALUE` where dialects differ, and replacing the DuckDB `MACRO`/`VALUES` constructs in the scenario model. The window functions, CTEs, and aggregation logic carry over unchanged.

---

## Reconciliation

Every figure below is asserted by `run_analysis.py` on each execution and matches the Excel workbook exactly.

| Metric | Value |
|---|---|
| Raw records | 548 |
| Duplicates removed | 14 (2.55%) |
| Null costs resolved | 27 (4.93%) |
| Clean records | 534 |
| Conversions | 67 |
| Total spend | $12,835.30 |
| Total revenue | $8,793.00 |
| Blended CPA | $191.57 |
| Portfolio ROI | -31.5% |
