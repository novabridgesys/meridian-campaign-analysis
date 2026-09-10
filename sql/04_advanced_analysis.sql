-- =============================================================================
-- 04_advanced_analysis.sql
-- Purpose : Analytical dimensions the original Excel version left unexploited:
--           lead aging, the cost/quality frontier, regional performance, and a
--           two-dimensional sensitivity grid on the reallocation decision.
-- Depends : 01_staging.sql
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Lead aging
--
-- Time to convert is an operational metric, not a marketing one. It sets the
-- attribution window: reporting conversion rate on a cohort younger than the
-- p90 lag understates performance, because leads that will convert have not
-- had the chance to yet.
--
-- days_to_convert is NULL for unconverted leads by design, so AVG reports the
-- mean among converters rather than a figure diluted toward zero.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lead_aging AS
SELECT
    channel,
    COUNT(*)                                                AS leads,
    SUM(is_converted)                                       AS conversions,
    ROUND(AVG(days_to_convert), 1)                          AS mean_days_to_convert,
    MEDIAN(days_to_convert)                                 AS median_days_to_convert,
    QUANTILE_CONT(days_to_convert, 0.90)                    AS p90_days_to_convert,
    MAX(days_to_convert)                                    AS max_days_to_convert,
    -- Share of conversions landing within 3 days. A channel that converts fast
    -- returns working capital faster even at equal ROI, which matters to a
    -- marketplace funding lead purchases before commissions settle.
    ROUND(100.0 * SUM(CASE WHEN days_to_convert <= 3 THEN 1 ELSE 0 END)
          / NULLIF(SUM(is_converted), 0), 1)                AS pct_converted_within_3d
FROM fct_leads
GROUP BY channel
ORDER BY mean_days_to_convert;


-- -----------------------------------------------------------------------------
-- Attribution window check
--
-- Quantifies how much of the reporting period is exposed to censoring. Leads
-- acquired in the final days of the month have not had time to convert, so
-- their measured conversion rate is structurally understated.
--
-- This is the analysis that stops someone concluding that late-month campaigns
-- underperformed when they were simply measured too early.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW attribution_censoring AS
WITH bounds AS (
    SELECT MAX(lead_date) AS period_end,
           QUANTILE_CONT(days_to_convert, 0.90) AS p90_lag
    FROM fct_leads
)
SELECT
    b.period_end,
    b.p90_lag                                                       AS p90_conversion_lag_days,
    COUNT(*) FILTER (
        WHERE DATE_DIFF('day', f.lead_date, b.period_end) < b.p90_lag
    )                                                               AS censored_leads,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE DATE_DIFF('day', f.lead_date, b.period_end) < b.p90_lag
    ) / COUNT(*), 1)                                                AS pct_leads_censored,
    ROUND(SUM(f.acquisition_cost) FILTER (
        WHERE DATE_DIFF('day', f.lead_date, b.period_end) < b.p90_lag
    ), 2)                                                           AS censored_spend
FROM fct_leads f
CROSS JOIN bounds b
GROUP BY b.period_end, b.p90_lag;


-- -----------------------------------------------------------------------------
-- Cost / quality frontier
--
-- Campaign-grain view feeding a CPA-versus-conversion-rate scatter. The
-- quadrant assignment turns a chart into a decision rule: it names what to do
-- with each campaign rather than leaving the reader to eyeball position.
--
-- Thresholds are the portfolio medians rather than round numbers, so the
-- classification adapts if the portfolio mix changes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW cost_quality_frontier AS
WITH campaign_stats AS (
    SELECT
        campaign_id,
        ANY_VALUE(advertiser)                                       AS advertiser,
        ANY_VALUE(vertical)                                         AS vertical,
        ANY_VALUE(channel)                                          AS channel,
        COUNT(*)                                                    AS leads,
        SUM(is_converted)                                           AS conversions,
        100.0 * SUM(is_converted) / COUNT(*)                        AS conversion_rate_pct,
        SUM(acquisition_cost)                                       AS total_cost,
        SUM(acquisition_cost) / COUNT(*)                            AS avg_cost_per_lead,
        SUM(commission_revenue) - SUM(acquisition_cost)             AS net_contribution
    FROM fct_leads
    GROUP BY campaign_id
),
thresholds AS (
    SELECT
        MEDIAN(conversion_rate_pct) AS median_cvr,
        MEDIAN(avg_cost_per_lead)   AS median_cpl
    FROM campaign_stats
)
SELECT
    c.campaign_id,
    c.advertiser,
    c.vertical,
    c.channel,
    c.leads,
    c.conversions,
    ROUND(c.conversion_rate_pct, 1)                                 AS conversion_rate_pct,
    ROUND(c.avg_cost_per_lead, 2)                                   AS avg_cost_per_lead,
    ROUND(c.total_cost, 2)                                          AS total_cost,
    ROUND(c.net_contribution, 2)                                    AS net_contribution,
    CASE
        WHEN c.conversion_rate_pct >= t.median_cvr
         AND c.avg_cost_per_lead   <  t.median_cpl THEN 'Scale: high quality, low cost'
        WHEN c.conversion_rate_pct >= t.median_cvr
         AND c.avg_cost_per_lead   >= t.median_cpl THEN 'Negotiate: high quality, high cost'
        WHEN c.conversion_rate_pct <  t.median_cvr
         AND c.avg_cost_per_lead   <  t.median_cpl THEN 'Monitor: low quality, low cost'
        ELSE 'Exit: low quality, high cost'
    END                                                             AS recommended_action
FROM campaign_stats c
CROSS JOIN thresholds t
ORDER BY c.net_contribution DESC;


-- -----------------------------------------------------------------------------
-- Regional performance
--
-- Rolls the state dimension up to region, where sample sizes support inference.
-- State-level cells are mostly too small to act on individually, which is
-- itself the finding.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW performance_by_region AS
SELECT
    CASE state
        WHEN 'CA' THEN 'West'      WHEN 'WA' THEN 'West'
        WHEN 'AZ' THEN 'West'      WHEN 'CO' THEN 'West'
        WHEN 'TX' THEN 'South'     WHEN 'FL' THEN 'South'
        WHEN 'GA' THEN 'South'     WHEN 'NC' THEN 'South'
        WHEN 'NY' THEN 'Northeast' WHEN 'PA' THEN 'Northeast'
        WHEN 'OH' THEN 'Midwest'   WHEN 'IL' THEN 'Midwest'
    END                                                             AS region,
    COUNT(*)                                                        AS leads,
    SUM(is_converted)                                               AS conversions,
    ROUND(100.0 * SUM(is_converted) / COUNT(*), 1)                  AS conversion_rate_pct,
    ROUND(SUM(acquisition_cost) / NULLIF(SUM(is_converted), 0), 2)  AS cpa,
    ROUND(SUM(commission_revenue) - SUM(acquisition_cost), 2)       AS net_contribution,
    ROUND(100.0 * (SUM(commission_revenue) - SUM(acquisition_cost))
          / NULLIF(SUM(acquisition_cost), 0), 1)                    AS roi_pct
FROM fct_leads
GROUP BY region
ORDER BY roi_pct DESC;


-- -----------------------------------------------------------------------------
-- Two-dimensional sensitivity grid
--
-- The single-scenario projection in the original analysis hid the fact that the
-- conclusion depends on two independent judgement calls: how aggressively to
-- cut, and how much efficiency survives redeployment at higher spend.
--
-- Varying both shows where the recommendation holds and where it breaks. A
-- projection presented as one number invites the reader to treat it as
-- forecast; a grid makes the uncertainty part of the finding.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sensitivity_grid AS
WITH affiliate_benchmark AS (
    SELECT (SUM(commission_revenue) - SUM(acquisition_cost)) / SUM(acquisition_cost) AS affiliate_roi
    FROM fct_leads
    WHERE channel = 'Affiliate'
),
cut_policies(policy, policy_rank) AS (
    VALUES ('A. Display only',                    1),
           ('B. Display + Life Insurance',        2),
           ('C. Display + Life + Medicare',       3)
),
haircuts(haircut_label, factor) AS (
    VALUES ('25% of benchmark', 0.25),
           ('50% of benchmark', 0.50),
           ('75% of benchmark', 0.75),
           ('100% of benchmark', 1.00)
),
segmented AS (
    SELECT
        p.policy,
        p.policy_rank,
        SUM(CASE WHEN
            (p.policy_rank >= 1 AND f.channel = 'Display')
         OR (p.policy_rank >= 2 AND f.vertical = 'Life Insurance')
         OR (p.policy_rank >= 3 AND f.vertical = 'Medicare')
            THEN f.acquisition_cost ELSE 0 END)                      AS cut_cost,
        SUM(CASE WHEN
            (p.policy_rank >= 1 AND f.channel = 'Display')
         OR (p.policy_rank >= 2 AND f.vertical = 'Life Insurance')
         OR (p.policy_rank >= 3 AND f.vertical = 'Medicare')
            THEN 0 ELSE f.commission_revenue END)                    AS retained_revenue,
        SUM(f.acquisition_cost)                                      AS total_cost,
        SUM(f.commission_revenue) - SUM(f.acquisition_cost)          AS baseline_net
    FROM fct_leads f
    CROSS JOIN cut_policies p
    GROUP BY p.policy, p.policy_rank
)
SELECT
    s.policy,
    h.haircut_label                                                  AS redeployment_efficiency,
    ROUND(s.cut_cost, 0)                                             AS spend_reallocated,
    ROUND(s.baseline_net, 0)                                         AS baseline_net,
    ROUND(s.retained_revenue + s.cut_cost * (1 + a.affiliate_roi * h.factor)
          - s.total_cost, 0)                                         AS projected_net,
    ROUND(s.retained_revenue + s.cut_cost * (1 + a.affiliate_roi * h.factor)
          - s.total_cost - s.baseline_net, 0)                        AS monthly_swing,
    CASE WHEN s.retained_revenue + s.cut_cost * (1 + a.affiliate_roi * h.factor)
              - s.total_cost >= 0
         THEN 'Profitable' ELSE 'Still loss-making' END              AS outcome
FROM segmented s
CROSS JOIN haircuts h
CROSS JOIN affiliate_benchmark a
ORDER BY s.policy_rank, h.factor;
