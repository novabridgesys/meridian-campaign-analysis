-- =============================================================================
-- 01_staging.sql
-- Purpose : Data quality layer. Deduplicate the raw lead feed and resolve
--           null acquisition costs against contracted campaign rates.
-- Grain   : One row per unique lead.
-- Engine  : DuckDB (ANSI-compatible; ports to BigQuery/Snowflake with minimal
--           change - see notes at each dialect-specific construct).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Source tables
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW raw_leads AS
SELECT * FROM read_csv_auto('data/raw_leads.csv');

CREATE OR REPLACE VIEW dim_campaign AS
SELECT
    "Campaign ID"                 AS campaign_id,
    "Advertiser"                  AS advertiser,
    "Vertical"                    AS vertical,
    "Channel"                     AS channel,
    "Base CPL"                    AS contracted_cpl,
    "Commission per Conversion"   AS commission_per_conversion
FROM read_csv_auto('data/campaign_reference.csv');


-- -----------------------------------------------------------------------------
-- Deduplication
--
-- The source feed contains exact duplicate lead records caused by webhook
-- retries and double submissions. ROW_NUMBER partitioned on the business key
-- is the idiomatic dedup pattern: it is deterministic, it keeps the earliest
-- record rather than an arbitrary one, and unlike SELECT DISTINCT it survives
-- the addition of columns that differ between otherwise-duplicate rows.
--
-- The ORDER BY inside the window makes "which duplicate we keep" an explicit
-- decision rather than an accident of scan order.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg_leads_deduplicated AS
WITH ranked AS (
    SELECT
        "Lead ID"       AS lead_id,
        CAST("Date" AS DATE) AS lead_date,
        CAST("Conversion Date" AS DATE) AS conversion_date,
        "Campaign ID"   AS campaign_id,
        "State"         AS state,
        "Lead Status"   AS lead_status,
        "Cost"          AS cost_raw,
        ROW_NUMBER() OVER (
            PARTITION BY "Lead ID"
            ORDER BY CAST("Date" AS DATE) ASC
        ) AS dedup_rank
    FROM raw_leads
)
SELECT
    lead_id,
    lead_date,
    conversion_date,
    campaign_id,
    state,
    lead_status,
    cost_raw
FROM ranked
WHERE dedup_rank = 1;


-- -----------------------------------------------------------------------------
-- Enrichment and null resolution
--
-- Null handling decision: a null acquisition cost is NOT dropped and NOT
-- treated as zero. Both approaches silently understate spend. Instead the
-- contracted rate for that campaign is substituted via COALESCE, and the
-- substitution is flagged in a dedicated column so downstream consumers can
-- isolate or exclude imputed rows.
--
-- Flagging the imputation is the part that matters. An imputed value that
-- cannot be identified downstream is indistinguishable from a measured one.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW fct_leads AS
SELECT
    l.lead_id,
    l.lead_date,
    DATE_TRUNC('week', l.lead_date)                     AS lead_week,
    l.conversion_date,
    -- Lead aging. NULL for unconverted leads, which is correct: the lag is
    -- undefined rather than zero. Averaging this column therefore reports mean
    -- time to convert among converters, not a blended figure diluted by leads
    -- that never converted.
    DATE_DIFF('day', l.lead_date, l.conversion_date)    AS days_to_convert,
    l.campaign_id,
    c.advertiser,
    c.vertical,
    c.channel,
    l.state,
    l.lead_status,

    CASE WHEN l.lead_status = 'Converted' THEN 1 ELSE 0 END AS is_converted,

    l.cost_raw,
    COALESCE(l.cost_raw, c.contracted_cpl)              AS acquisition_cost,
    CASE WHEN l.cost_raw IS NULL THEN TRUE ELSE FALSE END AS is_cost_imputed,

    CASE WHEN l.lead_status = 'Converted'
         THEN c.commission_per_conversion
         ELSE 0
    END                                                  AS commission_revenue

FROM stg_leads_deduplicated l
INNER JOIN dim_campaign c
    ON l.campaign_id = c.campaign_id;


-- -----------------------------------------------------------------------------
-- Data quality audit
--
-- Quantifies what cleaning changed. This runs as a check, not as decoration:
-- if the reconciliation numbers move unexpectedly on a future load, the
-- pipeline has a problem worth investigating before anyone reads a dashboard.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit_data_quality AS
WITH raw_stats AS (
    SELECT
        COUNT(*)                                          AS raw_row_count,
        COUNT(DISTINCT "Lead ID")                         AS distinct_lead_count,
        SUM(CASE WHEN "Cost" IS NULL THEN 1 ELSE 0 END)   AS null_cost_rows,
        SUM("Cost")                                       AS spend_ignoring_nulls
    FROM raw_leads
),
clean_stats AS (
    SELECT
        COUNT(*)                    AS clean_row_count,
        SUM(acquisition_cost)       AS spend_resolved,
        SUM(is_converted)           AS conversions,
        SUM(commission_revenue)     AS revenue
    FROM fct_leads
)
SELECT
    r.raw_row_count,
    c.clean_row_count,
    r.raw_row_count - c.clean_row_count                                  AS duplicates_removed,
    ROUND(100.0 * (r.raw_row_count - c.clean_row_count) / r.raw_row_count, 2)
                                                                          AS pct_feed_duplicated,
    r.null_cost_rows,
    ROUND(100.0 * r.null_cost_rows / r.raw_row_count, 2)                 AS pct_cost_null,
    ROUND(r.spend_ignoring_nulls, 2)                                     AS spend_if_nulls_ignored,
    ROUND(c.spend_resolved, 2)                                           AS spend_resolved,
    ROUND(c.spend_resolved - r.spend_ignoring_nulls, 2)                  AS spend_understatement,
    c.conversions,
    ROUND(c.revenue, 2)                                                  AS revenue
FROM raw_stats r
CROSS JOIN clean_stats c;
