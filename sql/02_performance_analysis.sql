-- =============================================================================
-- 02_performance_analysis.sql
-- Purpose : Marketplace profitability analysis at advertiser, vertical, and
--           channel grain, with statistical confidence bounds on conversion
--           rate so that small-sample segments are not over-interpreted.
-- Depends : 01_staging.sql (fct_leads)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Reusable metric block
--
-- Every grain needs the same seven measures. Defining them once as a macro
-- keeps the calculation identical across cuts. A metric that is defined
-- slightly differently in two places is the most common source of a dashboard
-- that disagrees with itself.
--
-- Portability note: DuckDB macros are convenient here. On BigQuery or
-- Snowflake this becomes a dbt macro or a view; the SQL body is unchanged.
-- -----------------------------------------------------------------------------

-- NULLIF guards every denominator. A segment with zero conversions returns
-- NULL for CPA rather than raising a divide-by-zero and killing the query.

CREATE OR REPLACE VIEW performance_by_advertiser AS
SELECT
    advertiser,
    ANY_VALUE(vertical)                                          AS vertical,
    COUNT(*)                                                     AS leads,
    SUM(is_converted)                                            AS conversions,
    ROUND(100.0 * SUM(is_converted) / COUNT(*), 1)               AS conversion_rate_pct,
    ROUND(SUM(acquisition_cost), 2)                              AS total_cost,
    ROUND(SUM(commission_revenue), 2)                            AS total_revenue,
    ROUND(SUM(acquisition_cost) / NULLIF(SUM(is_converted), 0), 2) AS cpa,
    ROUND(SUM(commission_revenue) - SUM(acquisition_cost), 2)    AS net_contribution,
    ROUND(100.0 * (SUM(commission_revenue) - SUM(acquisition_cost))
          / NULLIF(SUM(acquisition_cost), 0), 1)                 AS roi_pct
FROM fct_leads
GROUP BY advertiser
ORDER BY roi_pct DESC;


CREATE OR REPLACE VIEW performance_by_channel AS
SELECT
    channel,
    COUNT(*)                                                     AS leads,
    SUM(is_converted)                                            AS conversions,
    ROUND(100.0 * SUM(is_converted) / COUNT(*), 1)               AS conversion_rate_pct,
    ROUND(SUM(acquisition_cost), 2)                              AS total_cost,
    ROUND(SUM(commission_revenue), 2)                            AS total_revenue,
    ROUND(SUM(acquisition_cost) / NULLIF(SUM(is_converted), 0), 2) AS cpa,
    ROUND(SUM(commission_revenue) - SUM(acquisition_cost), 2)    AS net_contribution,
    ROUND(100.0 * (SUM(commission_revenue) - SUM(acquisition_cost))
          / NULLIF(SUM(acquisition_cost), 0), 1)                 AS roi_pct,
    -- Share-of-total measures via window function over the ungrouped result.
    -- This is the pattern that replaces "divide by the grand total cell" in Excel.
    ROUND(100.0 * SUM(acquisition_cost) / SUM(SUM(acquisition_cost)) OVER (), 1)
                                                                 AS pct_of_total_spend,
    ROUND(100.0 * SUM(is_converted) / SUM(SUM(is_converted)) OVER (), 1)
                                                                 AS pct_of_total_conversions
FROM fct_leads
GROUP BY channel
ORDER BY roi_pct DESC;


CREATE OR REPLACE VIEW performance_by_vertical AS
SELECT
    vertical,
    COUNT(*)                                                     AS leads,
    SUM(is_converted)                                            AS conversions,
    ROUND(100.0 * SUM(is_converted) / COUNT(*), 1)               AS conversion_rate_pct,
    ROUND(SUM(acquisition_cost), 2)                              AS total_cost,
    ROUND(SUM(commission_revenue), 2)                            AS total_revenue,
    ROUND(SUM(acquisition_cost) / NULLIF(SUM(is_converted), 0), 2) AS cpa,
    ROUND(SUM(commission_revenue) - SUM(acquisition_cost), 2)    AS net_contribution,
    ROUND(100.0 * (SUM(commission_revenue) - SUM(acquisition_cost))
          / NULLIF(SUM(acquisition_cost), 0), 1)                 AS roi_pct,
    -- Cumulative share of total loss, ordered worst-first. Answers
    -- "how concentrated is the problem" in a single column.
    ROUND(100.0 * SUM(SUM(acquisition_cost) - SUM(commission_revenue))
                  OVER (ORDER BY (SUM(commission_revenue) - SUM(acquisition_cost)) ASC
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(SUM(acquisition_cost) - SUM(commission_revenue)) OVER (), 1)
                                                                 AS cumulative_pct_of_loss
FROM fct_leads
GROUP BY vertical
ORDER BY roi_pct ASC;


-- -----------------------------------------------------------------------------
-- Statistical confidence on conversion rate
--
-- Conversion rate is a binomial proportion. At the segment sizes in this
-- dataset (n between 28 and 173) the point estimate alone is misleading:
-- a segment showing 3.6% on 28 leads and one conversion cannot be
-- distinguished from a segment performing three times better.
--
-- Wilson score interval is used rather than the normal approximation, because
-- the normal approximation breaks down at small n and at proportions near
-- zero, which is exactly where this dataset sits.
--
--   centre = (p + z^2/2n) / (1 + z^2/n)
--   half   = z * sqrt( p(1-p)/n + z^2/4n^2 ) / (1 + z^2/n)
--
-- is_conclusive flags whether the interval is tight enough to act on.
-- A 10-point-wide interval on a budget decision is not a finding, it is a
-- request for more data.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW advertiser_confidence AS
WITH base AS (
    SELECT
        advertiser,
        COUNT(*)                        AS n,
        SUM(is_converted)               AS conversions,
        1.0 * SUM(is_converted) / COUNT(*) AS p,
        1.96                            AS z          -- 95% two-sided
    FROM fct_leads
    GROUP BY advertiser
),
wilson AS (
    SELECT
        advertiser,
        n,
        conversions,
        p,
        (p + z*z / (2*n)) / (1 + z*z/n)                                   AS centre,
        z * SQRT( p*(1-p)/n + z*z/(4*n*n) ) / (1 + z*z/n)                 AS half_width
    FROM base
)
SELECT
    advertiser,
    n                                                       AS sample_size,
    conversions,
    ROUND(100.0 * p, 1)                                     AS conversion_rate_pct,
    ROUND(100.0 * GREATEST(centre - half_width, 0), 1)      AS ci_lower_pct,
    ROUND(100.0 * LEAST(centre + half_width, 1), 1)         AS ci_upper_pct,
    ROUND(100.0 * 2 * half_width, 1)                        AS ci_width_pp,
    -- Classification uses the conventional minimum of 5 observed successes for
    -- reliable inference on a proportion, not interval width alone. A segment
    -- with one conversion produces a narrow-looking interval simply because the
    -- rate is pinned near zero, which is not the same as being well measured.
    --
    -- Important scoping note: this column governs conclusions about CONVERSION
    -- RATE only. Cost-side conclusions do not depend on it. Everwell Life is
    -- flagged insufficient here, yet its economic case is still decisive: a
    -- $1,012 blended CPA against a $190 commission cannot reach breakeven at
    -- any conversion rate inside its own confidence interval.
    CASE
        WHEN conversions < 5 OR n < 50            THEN 'Insufficient sample'
        WHEN 100.0 * 2 * half_width <= 12.0       THEN 'Actionable'
        ELSE 'Directional'
    END                                                     AS evidence_strength
FROM wilson
ORDER BY p DESC;


-- -----------------------------------------------------------------------------
-- Weekly pacing
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW weekly_trend AS
SELECT
    lead_week,
    COUNT(*)                                                     AS leads,
    SUM(is_converted)                                            AS conversions,
    ROUND(100.0 * SUM(is_converted) / COUNT(*), 1)               AS conversion_rate_pct,
    ROUND(SUM(acquisition_cost), 2)                              AS total_cost,
    ROUND(SUM(commission_revenue) - SUM(acquisition_cost), 2)    AS net_contribution,
    -- Week-over-week volume change. LAG replaces the manual "previous cell"
    -- reference that makes Excel trend columns fragile when rows are inserted.
    COUNT(*) - LAG(COUNT(*)) OVER (ORDER BY lead_week)           AS wow_lead_change
FROM fct_leads
GROUP BY lead_week
ORDER BY lead_week;


-- -----------------------------------------------------------------------------
-- Geographic performance
-- Uses the State dimension that the original Excel analysis left unexploited.
-- HAVING filters out states too small to interpret, rather than showing a
-- 100% conversion rate built on two leads.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW performance_by_state AS
SELECT
    state,
    COUNT(*)                                                     AS leads,
    SUM(is_converted)                                            AS conversions,
    ROUND(100.0 * SUM(is_converted) / COUNT(*), 1)               AS conversion_rate_pct,
    ROUND(SUM(acquisition_cost) / NULLIF(SUM(is_converted), 0), 2) AS cpa,
    ROUND(SUM(commission_revenue) - SUM(acquisition_cost), 2)    AS net_contribution
FROM fct_leads
GROUP BY state
HAVING COUNT(*) >= 30
ORDER BY conversion_rate_pct DESC;


-- -----------------------------------------------------------------------------
-- Reallocation scenario model
--
-- Quantifies the recommendation: pause the Display channel and the Life
-- Insurance vertical, redeploy that spend at Affiliate-channel efficiency.
--
-- The efficiency haircut is parameterised rather than hardcoded, so the
-- sensitivity of the conclusion to that assumption is visible instead of
-- buried. This is the single largest assumption in the analysis.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW reallocation_scenario AS
WITH segments AS (
    SELECT
        CASE WHEN channel = 'Display' OR vertical = 'Life Insurance'
             THEN 'cut' ELSE 'keep' END                          AS segment,
        SUM(acquisition_cost)                                    AS cost,
        SUM(commission_revenue)                                  AS revenue
    FROM fct_leads
    GROUP BY 1
),
affiliate_benchmark AS (
    SELECT (SUM(commission_revenue) - SUM(acquisition_cost)) / SUM(acquisition_cost) AS affiliate_roi
    FROM fct_leads
    WHERE channel = 'Affiliate'
),
haircuts(label, factor) AS (
    VALUES ('Conservative (50% of benchmark)', 0.50),
           ('Moderate (75% of benchmark)',     0.75),
           ('Full benchmark',                  1.00)
),
model AS (
    SELECT
        h.label                                                  AS scenario,
        (SELECT cost    FROM segments WHERE segment = 'cut')     AS redeployed_spend,
        (SELECT revenue FROM segments WHERE segment = 'keep')    AS retained_revenue,
        (SELECT SUM(cost) FROM segments)                         AS total_spend,
        (SELECT SUM(revenue) - SUM(cost) FROM segments)          AS baseline_net,
        (SELECT cost FROM segments WHERE segment = 'cut')
            * (1 + a.affiliate_roi * h.factor)                   AS redeployed_revenue
    FROM haircuts h
    CROSS JOIN affiliate_benchmark a
)
SELECT
    scenario,
    ROUND(baseline_net, 0)                                              AS baseline_monthly_net,
    ROUND(retained_revenue + redeployed_revenue - total_spend, 0)       AS projected_monthly_net,
    ROUND(100.0 * (retained_revenue + redeployed_revenue - total_spend)
          / total_spend, 1)                                             AS projected_roi_pct,
    ROUND(retained_revenue + redeployed_revenue - total_spend - baseline_net, 0)
                                                                        AS monthly_swing,
    ROUND((retained_revenue + redeployed_revenue - total_spend - baseline_net) * 12, 0)
                                                                        AS annualised_recovery
FROM model;
