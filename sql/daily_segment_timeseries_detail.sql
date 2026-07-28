-- daily_segment_timeseries_detail
-- The base query (daily_segment_timeseries) taken down to master_id x day grain,
-- with per-customer detail columns added:
--   master_id, order_master_id, is_buyer, max_engagement_score,
--   intent_level_behavioral, add_to_cart, LC_Channel, device_type, Store,
--   customer_vs_user
--
-- Point-in-time segment assignment and KPI definitions are IDENTICAL to the base
-- query (INNER JOIN to segment_state_ranges, activity_date >= '2024-04-01', and
-- the same npb / orders / sessions definitions), so aggregating this detail by
-- [day] + segment attributes + business_line reproduces the base query exactly.

;WITH
segment_state_ranges AS (
    SELECT
        master_id,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,
        lifecycle_stage,
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

-- Calendar via cross-joined value tables (T-SQL has no explode/sequence)
calendar AS (
    SELECT TOP (DATEDIFF(DAY, '2024-01-01', GETDATE()) + 1)
           DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, CAST('2024-04-01' AS DATE)) AS day
    FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) a(n)   -- 10
    CROSS JOIN (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) b(n)   -- 10
    CROSS JOIN (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) c(n)   -- 10
    CROSS JOIN (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) d(n)   -- 10 → 10,000 rows total
),

daily_size AS (

    SELECT
        c.[day],
        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage,

        COUNT(*) AS customers_in_segment

    FROM calendar c

    INNER JOIN segment_state_ranges r
        ON c.[day] >= r.valid_from
       AND c.[day] <  r.valid_until

    GROUP BY
        c.[day],
        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage
),

buyer_flag AS (
    SELECT DISTINCT master_id
    FROM fct_customer_activity_agg
    WHERE OrderNumber IS NOT NULL
      AND ActiveOrderStatus = 1
),

-- Per-master, per-day activity detail using the base query's metric definitions.
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

        SUM(
            CASE
                WHEN f.engaged_session = 1
                THEN 1
                ELSE 0
            END
        ) AS engaged_sessions,

        MAX(f.engaged_session)          AS engaged_session,
        MAX(f.engagement_score_session) AS max_engagement_score,
        MAX(f.intent_level_behavioral)  AS intent_level_behavioral,
        SUM(f.add_to_cart)              AS add_to_cart,
        MAX(f.LC_Channel)  AS LC_Channel,
        MAX(f.device_type) AS device_type,
        MAX(f.Store)       AS Store

    FROM fct_customer_activity_agg f

    WHERE f.activity_date >= '2024-04-01'

    GROUP BY
        f.master_id,
        f.activity_date,
        f.business_line
)

SELECT
    d.[day],
    d.master_id,
    CASE WHEN d.orders > 0 THEN d.master_id END AS order_master_id,

    r.primary_segment,
    r.customer_maturity,
    r.session_substage,
    r.order_substage,
    d.business_line,

    s.customers_in_segment,

    COALESCE(d.sales_npbe,0)       AS sales_npbe,
    COALESCE(d.orders,0)           AS orders,
    COALESCE(d.total_sessions,0)   AS total_sessions,
    COALESCE(d.engaged_sessions,0) AS engaged_sessions,
    COALESCE(d.engaged_session,0)  AS engaged_session,

    CASE WHEN bf.master_id IS NOT NULL THEN 1 ELSE 0 END AS is_buyer,
    d.max_engagement_score,
    d.intent_level_behavioral,
    COALESCE(d.add_to_cart,0) AS add_to_cart,
    d.LC_Channel,
    d.device_type,
    d.Store,
    CASE WHEN r.lifecycle_stage IN ('Do', 'Care')
         THEN 'Customer' ELSE 'User' END AS customer_vs_user

FROM daily_detail d

INNER JOIN segment_state_ranges r
    ON d.master_id = r.master_id
   AND d.[day] >= r.valid_from
   AND d.[day] <  r.valid_until

LEFT JOIN daily_size s
    ON s.[day] = d.[day]

   AND (
         s.primary_segment = r.primary_segment
         OR (s.primary_segment IS NULL AND r.primary_segment IS NULL)
       )

   AND (
         s.customer_maturity = r.customer_maturity
         OR (s.customer_maturity IS NULL AND r.customer_maturity IS NULL)
       )

   AND (
         s.session_substage = r.session_substage
         OR (s.session_substage IS NULL AND r.session_substage IS NULL)
       )

   AND (
         s.order_substage = r.order_substage
         OR (s.order_substage IS NULL AND r.order_substage IS NULL)
       )

LEFT JOIN buyer_flag bf
    ON bf.master_id = d.master_id
