-- primary segmentation - monthly rollup by business_line
-- Reconciled to the base query (daily_segment_timeseries) logic.
--
-- This uses the SAME daily_kpis metric definitions as the base query so the
-- numbers reconcile: summing every primary_segment here equals the base query.
-- Differences that previously appeared vs the base query were caused by:
--   1. missing WHERE activity_date >= '2024-04-01' filter
--   2. counting total_users / active_users DISTINCT-per-month instead of the
--      base query's DISTINCT-per-day (summed = user-active-days)
--   3. LEFT JOIN to the snapshot (Unclassified) instead of the base INNER JOIN
--   4. different session / order metric plumbing
-- All four are aligned below.

;WITH
segment_state_ranges AS (
    SELECT
        master_id,
        primary_segment,
        secondary_segment,
        lifecycle_stage,
        order_substage,
        session_substage,
        customer_maturity,
        primary_confidence_pct,
        secondary_confidence_pct,
        snapshot_date AS valid_from,

        COALESCE(
            LEAD(snapshot_date) OVER (
                PARTITION BY master_id
                ORDER BY snapshot_date
            ),
            DATEADD(DAY, 1, CAST(GETDATE() AS DATE))
        ) AS valid_until

    FROM dbo.segment_customer_snapshot
),

-- Identical metric definitions to the base query's daily_kpis,
-- with the primary_segment breakdown carried through.
daily_kpis AS (

    SELECT
        f.activity_date AS [day],
        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage,
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

        COUNT(DISTINCT f.master_id) AS total_users,

        COUNT(
            DISTINCT CASE
                WHEN f.engaged_session = 1
                THEN f.master_id
            END
        ) AS active_users,

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

        SUM(
            CASE
                WHEN f.engaged_session = 1
                THEN 1
                ELSE 0
            END
        ) AS engaged_sessions

    FROM fct_customer_activity_agg f

    INNER JOIN segment_state_ranges r
        ON f.master_id = r.master_id
       AND f.activity_date >= r.valid_from
       AND f.activity_date <  r.valid_until

    WHERE f.activity_date >= '2024-04-01'

    GROUP BY
        f.activity_date,
        f.business_line,
        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage
)

SELECT
    YEAR([day])  AS [year],
    MONTH([day]) AS [month],
    business_line,
    SUM(sales_npbe)       AS npb_ordered,
    SUM(orders)           AS orders,
    SUM(total_users)      AS total_users,      -- user-active-days (matches base rollup)
    SUM(active_users)     AS active_users,     -- engaged user-active-days
    SUM(total_sessions)   AS total_sessions,
    SUM(engaged_sessions) AS engaged_sessions
FROM daily_kpis
GROUP BY
    YEAR([day]),
    MONTH([day]),
    business_line
ORDER BY
    [year],
    [month],
    business_line
