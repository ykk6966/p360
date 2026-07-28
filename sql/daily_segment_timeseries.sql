-- daily_segment_timeseries

WITH segment_state_ranges AS (
    SELECT
        master_id,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,
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

-- Calendar via recursive CTE (T-SQL has no explode/sequence)
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

daily_kpis AS (

    SELECT
        f.activity_date AS [day],
        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage,

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
        ) AS engaged_sessions,
        [business_line]

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
),

k as (

SELECT

    s.[day],
    s.primary_segment,
    s.customer_maturity,
    s.session_substage,
    s.order_substage,
    k.[business_line],
    s.customers_in_segment,

    COALESCE(k.sales_npbe,0)        AS sales_npbe,
    COALESCE(k.orders,0)            AS orders,
    COALESCE(k.total_users,0)       AS total_users,
    COALESCE(k.active_users,0)      AS active_users,
    COALESCE(k.total_sessions,0)    AS total_sessions,
    COALESCE(k.engaged_sessions,0)  AS engaged_sessions

FROM daily_size s

LEFT JOIN daily_kpis k
       ON s.[day] = k.[day]

      AND (
            s.primary_segment = k.primary_segment
            OR (s.primary_segment IS NULL AND k.primary_segment IS NULL)
          )

      AND (
            s.customer_maturity = k.customer_maturity
            OR (s.customer_maturity IS NULL AND k.customer_maturity IS NULL)
          )

      AND (
            s.session_substage = k.session_substage
            OR (s.session_substage IS NULL AND k.session_substage IS NULL)
          )

      AND (
            s.order_substage = k.order_substage
            OR (s.order_substage IS NULL AND k.order_substage IS NULL)
          )

)

select * from k
