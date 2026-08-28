/* ============================================================================
   CUSTOMER 360 — BROWSING AFFINITY (AGGREGATED / NO MASTER_ID)

   CATEGORY DEFINITION:
       Category = most_browsed_category

   PURPOSE:
       Optimized source for the S6 Browsing Affinity visual.

   IMPORTANT:
       - Keeps the validated engagement_agg logic untouched.
       - Uses only SQL-endpoint objects already used by engagement_agg:
           dbo.fct_customer_activity_agg
           dbo.segment_customer_snapshot
       - Resolves most_browsed_category at TRUE SESSION grain first.
       - Does NOT expose master_id in the final output.
       - Keeps NULL / blank most_browsed_category sessions as 'No Category'
         so affinity denominators can include ALL sessions.
       - Final table is session-based, not customer-grain.

   FINAL GRAIN:
       activity_date
       + Category
       + primary_segment
       + customer_maturity
       + business_line
       + LC_Channel
       + device_type
       + Store

   OUTPUT METRICS:
       sessions
       engaged_sessions
       orders
       NPBE

   INTERPRETATION:
       NPBE / Orders are outcomes associated with sessions whose
       most_browsed_category was the displayed category.
       They are NOT product-line category revenue / product-category orders.
   ============================================================================ */

WITH segment_state_ranges AS
(
    SELECT
        master_id,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,

        CAST(snapshot_date AS DATE) AS valid_from,

        COALESCE
        (
            LEAD(CAST(snapshot_date AS DATE)) OVER
            (
                PARTITION BY master_id
                ORDER BY snapshot_date
            ),
            DATEADD(DAY, 1, CAST(GETDATE() AS DATE))
        ) AS valid_until

    FROM dbo.segment_customer_snapshot

    WHERE master_id IS NOT NULL
      AND snapshot_date IS NOT NULL
),

/* ============================================================================
   POINT-IN-TIME BASE FACT
   ============================================================================ */
base_fact AS
(
    SELECT
        f.activity_date,
        YEAR(f.activity_date)  AS activity_year,
        MONTH(f.activity_date) AS activity_month,

        f.master_id,
        f.user_pseudo_id,
        f.ga_session_id,
        f.row_type,
        f.has_behavioral_data,

        f.OrderNumber,
        f.ActiveOrderStatus,
        f.npb_ordered,

        f.business_line,
        f.LC_Channel,
        f.device_type,
        f.Store,

        f.engaged_session,
        f.most_browsed_category,

        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage

    FROM dbo.fct_customer_activity_agg f

    INNER JOIN segment_state_ranges r
        ON f.master_id = r.master_id
       AND f.activity_date >= r.valid_from
       AND f.activity_date <  r.valid_until

    WHERE f.activity_date >= '2024-04-01'
),

/* ============================================================================
   ACTIVE ORDER GRAIN
   Same active-order grain used by the validated engagement logic.
   ============================================================================ */
order_grain AS
(
    SELECT
        activity_date,
        activity_year,
        activity_month,
        master_id,
        OrderNumber,

        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,

        COALESCE(MAX(business_line), 'Unassigned') AS business_line,
        COALESCE(MAX(LC_Channel),   'Unassigned') AS LC_Channel,
        COALESCE(MAX(device_type),  'Unassigned') AS device_type,
        COALESCE(MAX(Store),        'Unassigned') AS Store,

        CAST
        (
            SUM(COALESCE(npb_ordered, 0))
            AS DECIMAL(38,12)
        ) AS NPBE

    FROM base_fact

    WHERE OrderNumber IS NOT NULL
      AND ActiveOrderStatus = 1

    GROUP BY
        activity_date,
        activity_year,
        activity_month,
        master_id,
        OrderNumber,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage
),

/* ============================================================================
   SESSION DIMENSION SELECTION

   Official C360 session key:
       activity_date + user_pseudo_id + ga_session_id
   ============================================================================ */
session_dimension_candidates AS
(
    SELECT
        f.activity_date,
        f.activity_year,
        f.activity_month,
        f.user_pseudo_id,
        f.ga_session_id,
        f.master_id,

        f.primary_segment,
        f.customer_maturity,
        f.session_substage,
        f.order_substage,

        COALESCE(f.business_line, og.business_line, 'Unassigned') AS business_line,
        COALESCE(f.LC_Channel,   og.LC_Channel,   'Unassigned') AS LC_Channel,
        COALESCE(f.device_type,  og.device_type,  'Unassigned') AS device_type,
        COALESCE(f.Store,        og.Store,        'Unassigned') AS Store,

        COUNT(*) OVER
        (
            PARTITION BY
                f.activity_date,
                f.user_pseudo_id,
                f.ga_session_id,
                f.master_id
        ) AS master_row_count,

        (
            CASE
                WHEN f.business_line IS NOT NULL OR og.business_line IS NOT NULL
                THEN 1 ELSE 0
            END
          + CASE
                WHEN f.LC_Channel IS NOT NULL OR og.LC_Channel IS NOT NULL
                THEN 1 ELSE 0
            END
          + CASE
                WHEN f.device_type IS NOT NULL OR og.device_type IS NOT NULL
                THEN 1 ELSE 0
            END
          + CASE
                WHEN f.Store IS NOT NULL OR og.Store IS NOT NULL
                THEN 1 ELSE 0
            END
        ) AS dimension_completeness

    FROM base_fact f

    LEFT JOIN order_grain og
        ON f.activity_date = og.activity_date
       AND f.master_id     = og.master_id
       AND f.OrderNumber   = og.OrderNumber

    WHERE f.has_behavioral_data = 1
      AND f.ga_session_id IS NOT NULL
      AND f.user_pseudo_id IS NOT NULL
),

session_dimension_ranked AS
(
    SELECT
        *,

        ROW_NUMBER() OVER
        (
            PARTITION BY
                activity_date,
                user_pseudo_id,
                ga_session_id

            ORDER BY
                master_row_count DESC,
                dimension_completeness DESC,
                master_id
        ) AS rn

    FROM session_dimension_candidates
),

session_dimensions AS
(
    SELECT
        activity_date,
        activity_year,
        activity_month,
        user_pseudo_id,
        ga_session_id,

        primary_segment,
        customer_maturity,

        business_line,
        LC_Channel,
        device_type,
        Store

    FROM session_dimension_ranked

    WHERE rn = 1
),

/* ============================================================================
   TRUE SESSION METRICS

   most_browsed_category is resolved at TRUE SESSION grain here.
   ============================================================================ */
engagement_session_metrics AS
(
    SELECT
        activity_date,
        user_pseudo_id,
        ga_session_id,

        MAX(COALESCE(engaged_session, 0)) AS engaged_session,

        MAX(most_browsed_category) AS most_browsed_category,

        COUNT(DISTINCT OrderNumber) AS session_orders,

        CAST
        (
            SUM(COALESCE(npb_ordered, 0))
            AS DECIMAL(38,12)
        ) AS session_npbe

    FROM base_fact

    WHERE has_behavioral_data = 1
      AND row_type <> 'pre_ga4_order'
      AND ga_session_id IS NOT NULL
      AND user_pseudo_id IS NOT NULL

    GROUP BY
        activity_date,
        user_pseudo_id,
        ga_session_id
),

/* ============================================================================
   ONE ROW PER TRUE SESSION
   ============================================================================ */
engagement_session_grain AS
(
    SELECT
        d.activity_date,
        d.activity_year,
        d.activity_month,

        d.user_pseudo_id,
        d.ga_session_id,

        d.primary_segment,
        d.customer_maturity,

        d.business_line,
        d.LC_Channel,
        d.device_type,
        d.Store,

        m.most_browsed_category,
        m.engaged_session,
        m.session_orders,
        m.session_npbe

    FROM session_dimensions d

    INNER JOIN engagement_session_metrics m
        ON d.activity_date   = m.activity_date
       AND d.user_pseudo_id = m.user_pseudo_id
       AND d.ga_session_id  = m.ga_session_id
),

/* ============================================================================
   FINAL BROWSING AFFINITY AGGREGATION

   IMPORTANT:
       NULL / blank categories are retained as 'No Category'.
       This is necessary so Power BI can calculate affinity using ALL sessions
       as the denominator.

   Example:
       Vitamins sessions / ALL Planner sessions
   rather than
       Vitamins sessions / only categorized Planner sessions
   ============================================================================ */
browsing_affinity AS
(
    SELECT
        activity_date,
        activity_year,
        activity_month,

        COALESCE
        (
            NULLIF(LTRIM(RTRIM(most_browsed_category)), ''),
            'No Category'
        ) AS Category,

        primary_segment,
        customer_maturity,

        business_line,
        LC_Channel,
        device_type,
        Store,

        COUNT_BIG(*) AS sessions,

        SUM
        (
            CAST
            (
                CASE
                    WHEN engaged_session = 1 THEN 1
                    ELSE 0
                END
                AS BIGINT
            )
        ) AS engaged_sessions,

        SUM(CAST(session_orders AS BIGINT)) AS orders,

        CAST
        (
            SUM(COALESCE(session_npbe, 0))
            AS DECIMAL(38,12)
        ) AS NPBE

    FROM engagement_session_grain

    GROUP BY
        activity_date,
        activity_year,
        activity_month,

        COALESCE
        (
            NULLIF(LTRIM(RTRIM(most_browsed_category)), ''),
            'No Category'
        ),

        primary_segment,
        customer_maturity,

        business_line,
        LC_Channel,
        device_type,
        Store
)

/* ============================================================================
   FINAL POWER BI OUTPUT
   ============================================================================ */
SELECT
    activity_date,
    activity_year,
    activity_month,

    Category,

    primary_segment,
    customer_maturity,

    business_line,
    LC_Channel,
    device_type,
    Store,

    CASE
        WHEN customer_maturity IN
        (
            'Anonymous New User',
            'Identified New User'
        )
        THEN 'New User'

        WHEN customer_maturity IN
        (
            'Anonymous Returning User',
            'Identified Returning User',
            'New Customer',
            'Returning Customer'
        )
        THEN 'Returning User'

        ELSE NULL
    END AS New_ret,

    sessions,
    engaged_sessions,
    orders,
    NPBE

FROM browsing_affinity;
