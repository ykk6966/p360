-- primary segmentation - monthly rollup by business_line
-- Aggregates the point-in-time primary segmentation output up to
-- year / month / business_line, reproducing the reviewed results grid:
--   year, month, total_users, active_users, order_count, total_sessions, npb_ordered, business_line
-- Segment attributes are still resolved point-in-time via segment_state_ranges
-- (valid_from / valid_until built with LEAD), matching daily_segment_timeseries.

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

daily_orders AS (
    SELECT
        master_id,
        activity_date,
        COUNT(DISTINCT CASE WHEN OrderNumber IS NOT NULL THEN OrderNumber END) AS orders,
        SUM(COALESCE(npb_ordered, 0))                                          AS npbe,
        CASE WHEN COUNT(DISTINCT CASE WHEN OrderNumber IS NOT NULL THEN OrderNumber END) > 0
             THEN 1 ELSE 0 END                                                 AS is_buyer_on_date
    FROM dbo.fct_customer_activity_agg
    WHERE ActiveOrderStatus = 1
      AND activity_date IS NOT NULL
    GROUP BY master_id, activity_date
),
daily_sessions AS (
    SELECT master_id, activity_date,
           COUNT(ga_session_id) AS total_sessions,
           MAX(engaged_session)          AS engaged_session,
           MAX(engagement_score_session) AS max_engagement_score,
           MAX(intent_level_behavioral)  AS intent_level_behavioral,
           SUM(add_to_cart)              AS add_to_cart,
           MAX(LC_Channel)    AS LC_Channel,
           MAX(device_type)   AS device_type,
           MAX(Store)         AS Store,
           MAX(business_line) AS business_line
    FROM dbo.fct_customer_activity_agg
    GROUP BY master_id, activity_date
),
daily AS (
    SELECT
        COALESCE(ds.master_id,     dor.master_id)     AS master_id,
        COALESCE(ds.activity_date, dor.activity_date) AS activity_date,
        dor.orders,
        dor.npbe,
        dor.is_buyer_on_date,
        ds.total_sessions,
        ds.engaged_session,
        ds.max_engagement_score,
        ds.intent_level_behavioral,
        ds.add_to_cart,
        ds.LC_Channel,
        ds.device_type,
        ds.Store,
        ds.business_line
    FROM      daily_sessions ds
    FULL OUTER JOIN daily_orders dor
        ON ds.master_id = dor.master_id
       AND ds.activity_date = dor.activity_date
),
k AS (
    SELECT
        d.master_id,
        d.activity_date,
        COALESCE(r.primary_segment,   'Unclassified') AS primary_segment,
        COALESCE(r.secondary_segment, 'Unclassified') AS secondary_segment,
        r.lifecycle_stage,
        r.order_substage,
        r.session_substage,
        r.customer_maturity,
        COALESCE(d.orders,           0) AS orders,
        COALESCE(d.npbe,             0) AS npbe,
        COALESCE(d.is_buyer_on_date, 0) AS is_buyer_on_date,
        COALESCE(d.total_sessions,   0) AS total_sessions,
        COALESCE(d.engaged_session,  0) AS engaged_session,
        d.business_line
    FROM      daily d
    LEFT JOIN segment_state_ranges r
           ON r.master_id      = d.master_id
          AND d.activity_date >= r.valid_from
          AND d.activity_date <  r.valid_until
)

SELECT
    YEAR(k.activity_date)  AS [year],
    MONTH(k.activity_date) AS [month],
    COUNT(DISTINCT k.master_id)                                            AS total_users,
    COUNT(DISTINCT CASE WHEN k.engaged_session = 1 THEN k.master_id END)   AS active_users,
    SUM(k.orders)                                                          AS order_count,
    SUM(k.total_sessions)                                                  AS total_sessions,
    SUM(k.npbe)                                                            AS npb_ordered,
    k.business_line
FROM k
WHERE k.activity_date IS NOT NULL
GROUP BY
    YEAR(k.activity_date),
    MONTH(k.activity_date),
    k.business_line
ORDER BY
    [year],
    [month],
    k.business_line
