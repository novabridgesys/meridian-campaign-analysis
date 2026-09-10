-- =============================================================================
-- 03_export_powerbi.sql
-- Purpose : Materialise a star schema for the Power BI semantic model.
-- Depends : 01_staging.sql
--
-- Design note: Power BI is exported a STAR SCHEMA, not the single flat table
-- the Excel version used. Flat tables work until you need a measure to slice
-- consistently across two dimensions, at which point they force either
-- duplicated logic or a bidirectional filter. Conforming dimensions with
-- single-direction relationships from dim to fact keep the model predictable
-- and the DAX simple.
--
-- A dedicated date dimension is mandatory for Power BI time intelligence.
-- Without one, functions like DATEADD and TOTALYTD silently misbehave.
-- =============================================================================

-- Fact table: one row per lead, foreign keys only, no descriptive attributes.
COPY (
    SELECT
        lead_id,
        lead_date,
        campaign_id,
        state           AS state_code,
        lead_status,
        is_converted,
        acquisition_cost,
        commission_revenue,
        is_cost_imputed
    FROM fct_leads
    ORDER BY lead_date, lead_id
) TO 'powerbi/fct_leads.csv' (HEADER, DELIMITER ',');


-- Campaign dimension.
COPY (
    SELECT
        campaign_id,
        advertiser,
        vertical,
        channel,
        contracted_cpl,
        commission_per_conversion
    FROM dim_campaign
    ORDER BY campaign_id
) TO 'powerbi/dim_campaign.csv' (HEADER, DELIMITER ',');


-- Date dimension. Built as a contiguous calendar spanning the fact table,
-- with no gaps. Gaps break time intelligence.
COPY (
    WITH bounds AS (
        SELECT MIN(lead_date) AS d0, MAX(lead_date) AS d1 FROM fct_leads
    ),
    calendar AS (
        SELECT UNNEST(generate_series(
            (SELECT d0 FROM bounds),
            (SELECT d1 FROM bounds),
            INTERVAL 1 DAY
        ))::DATE AS date_key
    )
    SELECT
        date_key,
        YEAR(date_key)                                      AS year,
        MONTH(date_key)                                     AS month_number,
        MONTHNAME(date_key)                                 AS month_name,
        DATE_TRUNC('week', date_key)::DATE                  AS week_start,
        'Week ' || CAST(
            DENSE_RANK() OVER (ORDER BY DATE_TRUNC('week', date_key)) AS VARCHAR
        )                                                   AS week_label,
        DAYNAME(date_key)                                   AS day_name,
        DAYOFWEEK(date_key)                                 AS day_of_week_number,
        CASE WHEN DAYOFWEEK(date_key) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend
    FROM calendar
    ORDER BY date_key
) TO 'powerbi/dim_date.csv' (HEADER, DELIMITER ',');


-- State dimension. Small, but keeps geography filtering off the fact table
-- and gives a natural home for future attributes such as region or licensing.
COPY (
    SELECT DISTINCT
        state        AS state_code,
        CASE state
            WHEN 'CA' THEN 'West'      WHEN 'WA' THEN 'West'
            WHEN 'AZ' THEN 'West'      WHEN 'CO' THEN 'West'
            WHEN 'TX' THEN 'South'     WHEN 'FL' THEN 'South'
            WHEN 'GA' THEN 'South'     WHEN 'NC' THEN 'South'
            WHEN 'NY' THEN 'Northeast' WHEN 'PA' THEN 'Northeast'
            WHEN 'OH' THEN 'Midwest'   WHEN 'IL' THEN 'Midwest'
        END          AS region
    FROM fct_leads
    ORDER BY state_code
) TO 'powerbi/dim_state.csv' (HEADER, DELIMITER ',');
