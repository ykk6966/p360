-- Monthly KPIs by business_line  (CORRECT / canonical rollup)
--
-- Produces the standard grid:
--   year, month, total_users, active_users, order_count, total_sessions,
--   npb_ordered, business_line
--
-- Why this is the correct version:
--   * total_users / active_users use COUNT(DISTINCT master_id) over the MONTH
--     (true distinct users). The base query (daily_segment_timeseries) is
--     pre-aggregated at the daily grain, so its monthly rollup can only SUM
--     daily distinct counts = user-active-days, which overstates users.
--   * Additive metrics (orders, npb, sessions) use the base query's exact
--     definitions, so they reconcile with the base query.
--   * Point-in-time snapshot membership is applied via EXISTS (not a JOIN) so
--     overlapping / duplicate snapshots cannot fan out and double-count the
--     additive metrics.

;WITH
segment_state_ranges AS (
    SELECT
        master_id,
        snapshot_date AS valid_from,
        COALESCE(
            LEAD(snapshot_date) OVER (
                PARTITION BY master_id
                ORDER BY snapshot_date
            ),
            DATEADD(DAY, 1, CAST(GETDATE() AS DATE))
        ) AS valid_until
    FROM segment_customer_snapshot
),

-- Per-master, per-day activity using the base query's metric definitions.
daily_detail AS (

    SELECT
        f.master_id,
        f.activity_date AS [day],
        f.business_line,

        SUM(
            CASE
                WHEN f.ActiveOrderStatus = 1
                THEN COALESCE(f.npb_ordered,0)
                ELSE 0
            END
        ) AS sales_npbe,

        COUNT(
            DISTINCT CASE
                WHEN f.OrderNumber IS NOT NULL
                 AND f.ActiveOrderStatus = 1
                THEN f.OrderNumber
            END
        ) AS orders,

        SUM(
            CASE
                WHEN f.row_type IN (
                    'ga4_session_with_order',
                    'ga4_order_no_session_start',
                    'ga4_session_browse_only'
                )
                THEN 1
                ELSE 0
            END
        ) AS total_sessions,

        MAX(f.engaged_session) AS engaged_session

    FROM fct_customer_activity_agg f

    WHERE f.activity_date >= '2024-04-01'

    GROUP BY
        f.master_id,
        f.activity_date,
        f.business_line
)

SELECT
    YEAR(d.[day])  AS [year],
    MONTH(d.[day]) AS [month],

    COUNT(DISTINCT d.master_id)                                          AS total_users,
    COUNT(DISTINCT CASE WHEN d.engaged_session = 1 THEN d.master_id END) AS active_users,
    SUM(d.orders)                                                        AS order_count,
    SUM(d.total_sessions)                                                AS total_sessions,
    SUM(d.sales_npbe)                                                    AS npb_ordered,

    d.business_line

FROM daily_detail d

-- Point-in-time snapshot membership (matches the base query population)
-- without fanning out on overlapping snapshots.
WHERE EXISTS (
    SELECT 1
    FROM segment_state_ranges r
    WHERE r.master_id   = d.master_id
      AND d.[day]      >= r.valid_from
      AND d.[day]       < r.valid_until
)

GROUP BY
    YEAR(d.[day]),
    MONTH(d.[day]),
    d.business_line

ORDER BY
    [year],
    [month],
    d.business_line
