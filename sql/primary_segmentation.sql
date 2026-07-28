-- primary segment (point-in-time)
-- Primary segmentation query with the base query (daily_segment_timeseries) logic applied:
-- segment attributes are resolved point-in-time via segment_state_ranges
-- (valid_from / valid_until built with LEAD) and joined to activity on
-- activity_date within [valid_from, valid_until), instead of using the latest snapshot.
-- Output columns are identical to the original primary segmentation query.

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

buyer_flag AS (
    SELECT DISTINCT master_id
    FROM dbo.fct_customer_activity_agg
    WHERE OrderNumber IS NOT NULL
      AND ActiveOrderStatus = 1
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
          -- COUNT(CASE WHEN ga_session_id IS NOT NULL AND ga_session_id <> '' THEN 1 END) AS total_sessions,
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
    --WHERE ActiveOrderStatus = 1
  --AND activity_date IS NOT NULL
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
seg_active AS (
    SELECT COALESCE(r.primary_segment, 'Unclassified') AS primary_segment,
           COUNT(DISTINCT CASE WHEN d.engaged_session = 1 THEN d.master_id END) AS active_users
    FROM      daily d
    LEFT JOIN segment_state_ranges r
           ON r.master_id      = d.master_id
          AND d.activity_date >= r.valid_from
          AND d.activity_date <  r.valid_until
    GROUP BY COALESCE(r.primary_segment, 'Unclassified')
),
k as (
--actual primary segment query validated (point-in-time segment_state_ranges applied):



SELECT
        d.master_id,
        CASE WHEN d.orders > 0 THEN d.master_id END AS order_master_id,
        d.activity_date,
        COALESCE(r.primary_segment,   'Unclassified') AS primary_segment,
        COALESCE(r.secondary_segment, 'Unclassified') AS secondary_segment,
        r.lifecycle_stage,
        r.order_substage,
        r.session_substage,
        r.customer_maturity,
        r.primary_confidence_pct,
        r.secondary_confidence_pct,
        CASE WHEN bf.master_id IS NOT NULL THEN 1 ELSE 0 END AS is_buyer,
        COALESCE(d.orders,           0) AS orders,
        COALESCE(d.npbe,             0) AS npbe,
        COALESCE(d.is_buyer_on_date, 0) AS is_buyer_on_date,
        COALESCE(d.total_sessions,   0) AS total_sessions,
        COALESCE(d.engaged_session,  0) AS engaged_session,
        sa.active_users,
        d.max_engagement_score,
        d.intent_level_behavioral,
        COALESCE(d.add_to_cart,      0) AS add_to_cart,
        d.LC_Channel,
        d.device_type,
        d.Store,
        d.business_line,
        CASE WHEN r.lifecycle_stage IN ('Do', 'Care')
             THEN 'Customer' ELSE 'User' END AS customer_vs_user
    FROM      daily d
    LEFT JOIN segment_state_ranges r
           ON r.master_id      = d.master_id
          AND d.activity_date >= r.valid_from
          AND d.activity_date <  r.valid_until
    LEFT JOIN buyer_flag  bf ON bf.master_id = d.master_id
    LEFT JOIN seg_active  sa ON sa.primary_segment = COALESCE(r.primary_segment, 'Unclassified')
)


select * from k
