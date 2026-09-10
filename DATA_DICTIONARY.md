# Data Dictionary

All data is synthetic. No real advertiser, client, or consumer data is used.
The committed CSVs in `data/` are the source of truth for the analysis.

---

## `data/raw_leads.csv` (548 rows)

The lead feed as received from the ingestion layer, before cleaning. Contains
deliberate quality defects.

| Column | Type | Description | Notes |
|---|---|---|---|
| `Lead ID` | text | Business key, format `L#####` | Not unique in this file: 14 rows are exact duplicates from simulated webhook retries |
| `Date` | date | Date the lead was acquired | July 2026, 31-day period |
| `Campaign ID` | text | Foreign key to campaign reference, format `CMP-###` | 13 distinct campaigns |
| `State` | text | Two-letter US state code | 12 states. Assigned independently of conversion outcome |
| `Lead Status` | text | `Converted`, `Rejected`, `No Contact`, `In Progress` | Only `Converted` generates revenue |
| `Cost` | decimal | Acquisition cost paid for the lead | Null in 27 rows (4.9%), simulating incomplete platform reporting |
| `Conversion Date` | date | Date the lead converted | Null for all non-converted leads |

## `data/campaign_reference.csv` (13 rows)

Commercial reference table. One row per campaign.

| Column | Type | Description |
|---|---|---|
| `Campaign ID` | text | Primary key |
| `Advertiser` | text | Advertiser partner. 8 distinct advertisers, some running multiple campaigns |
| `Vertical` | text | Health, Life, Auto, Home Insurance, or Medicare |
| `Channel` | text | Paid Search, Paid Social, Native, Affiliate, or Display |
| `Base CPL` | integer | Contracted cost per lead. Used as the imputation fallback for null costs |
| `Commission per Conversion` | integer | Fixed commission earned on each converted lead |

---

## Derived fields (`fct_leads`, created in `sql/01_staging.sql`)

| Column | Derivation |
|---|---|
| `lead_week` | `DATE_TRUNC('week', lead_date)` |
| `days_to_convert` | `DATE_DIFF('day', lead_date, conversion_date)`. Null for unconverted leads, so averages report mean lag among converters rather than a figure diluted toward zero |
| `is_converted` | `1` when `lead_status = 'Converted'`, else `0`. Additive flag, so `SUM` gives conversion count |
| `acquisition_cost` | `COALESCE(cost_raw, contracted_cpl)`. Null costs resolved to the campaign's contracted rate |
| `is_cost_imputed` | `TRUE` where `cost_raw` was null. Carried through so imputed rows can be isolated downstream |
| `commission_revenue` | `commission_per_conversion` when converted, else `0` |

---

## Metric definitions

Defined once and referenced everywhere, so no two views can disagree.

| Metric | Definition | Guard |
|---|---|---|
| Conversion rate | `conversions / leads` | |
| CPA | `total_cost / conversions` | `NULLIF` on denominator. Null, not zero, when a segment has no conversions |
| Net contribution | `total_revenue - total_cost` | |
| ROI | `net_contribution / total_cost` | `NULLIF` on denominator |
| Efficiency index | `(share of conversions) / (share of spend)` | Above 1.0 means the segment returns more conversion share than the budget share it consumes |

---

## Known limitations

Stated plainly because they bound what the analysis can support.

1. **Single 31-day period.** No seasonality, no year-over-year comparison, and no way to confirm a finding on a holdout period.
2. **Attribution censoring.** Leads acquired in the final six days have not had time to reach the p90 conversion lag. 20.2% of leads and $2,547 of spend sit inside that window, so late-period conversion rates are structurally understated. Quantified in `attribution_censoring`.
3. **No lead-quality attributes.** No consumer demographics, intent signals, or form-completion data, so the analysis can identify *that* a channel underperforms but not *why*.
4. **No supplier or placement detail.** Channel is the finest available grain on the media side. A Display underperformance finding cannot be traced to specific placements.
5. **Small segments.** Several advertiser cells fall below the threshold for reliable inference on conversion rate. Flagged per-segment in `advertiser_confidence` rather than left to the reader.
