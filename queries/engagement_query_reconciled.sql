-- ════════════════════════════════════════════════════════════════
-- Reconciled engagement query
--
-- Goal: the shared KPI columns (sales_npbe, orders, total_users,
-- active_users, total_sessions, engaged_sessions) tie out EXACTLY to
-- base_query.sql at the same grain and under a monthly rollup.
--
-- Alignments vs the original engagement_query.sql:
--   1. Dropped the `has_behavioral_data = 1 AND row_type <> 'pre_ga4_order'`
--      filter — base_query.sql applies no such filter (only activity_date
--      >= '2024-04-01'). This restores the pre-GA4 months and the
--      non-behavioral orders/revenue.
--   2. Added `ActiveOrderStatus = 1` to the revenue and order counts,
--      matching base_query.sql's order/revenue definition.
--   3. total_sessions uses base_query.sql's row_type-based definition
--      (count of GA4 session/order rows), not COUNT(DISTINCT ga_session_id).
--   4. KPIs are aggregated at base_query.sql's grain:
--        activity_date + business_line + primary_segment + customer_maturity
--        + session_substage + order_substage
--      The finer dimensions (device_type, LC_Channel, Store, Operating_system,
--      landing/exit page, intent_level_behavioral) are intentionally NOT in
--      the grouping — keeping them splits users/sessions across groups and
--      inflates summed distinct counts, which is exactly what broke the
--      tie-out before. The original engagement_query.sql still retains that
--      full dimensional detail.
--
-- Engagement-specific metrics (browsing depth, search, ATC/cart, brand &
-- category browsing, engagement score, duration) are computed on a
-- one-row-per-session collapse (MAX per session) and attached at the base
-- grain via a NULL-safe LEFT JOIN, so they never affect the KPI tie-out.
-- ════════════════════════════════════════════════════════════════
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

activity AS (
    SELECT
        f.activity_date,
        YEAR(f.activity_date)  AS activity_year,
        MONTH(f.activity_date) AS activity_month,

        f.business_line,
        r.primary_segment,
        r.customer_maturity,
        r.session_substage,
        r.order_substage,

        f.master_id,
        f.ga_session_id,
        f.OrderNumber,
        f.ActiveOrderStatus,
        f.npb_ordered,
        f.row_type,
        f.engaged_session,
        f.logged_in_during_session,

        -- engagement per-row measures (collapsed per session downstream)
        f.engagement_score_session,
        f.session_duration_seconds,
        f.unique_pdp_view_count,
        f.unique_plp_view_count,
        f.unique_search_count,
        f.unique_products_atc,
        f.cart_value_atc,
        f.unique_brand_count_lists,
        f.unique_brand_count_pdp,
        f.unique_category_count_lists,
        f.unique_category_count_pdp,
        f.unique_brand_count_search,
        f.unique_category_count_search,
        f.add_to_cart,
        f.visited_cart,
        f.visited_checkout,
        f.purchased_GA4,
        f.most_browsed_category,
        f.most_browsed_brand

    FROM [dbo].[fct_customer_activity_agg] f
    INNER JOIN segment_state_ranges r
        ON f.master_id = r.master_id
       AND f.activity_date >= r.valid_from
       AND f.activity_date <  r.valid_until
    WHERE f.activity_date >= '2024-04-01'
),

-- ────────────────────────────────────────────────────────────────
-- Base-aligned KPIs: identical source, filter, grain, and metric
-- definitions as base_query.sql's daily_kpis → guarantees tie-out.
-- ────────────────────────────────────────────────────────────────
daily_kpis AS (
    SELECT
        activity_date,
        activity_year,
        activity_month,
        business_line,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,

        SUM(
            CASE
                WHEN ActiveOrderStatus = 1
                THEN COALESCE(npb_ordered, 0)
                ELSE 0
            END
        ) AS sales_npbe,

        COUNT(
            DISTINCT CASE
                WHEN OrderNumber IS NOT NULL
                 AND ActiveOrderStatus = 1
                THEN OrderNumber
            END
        ) AS orders,

        COUNT(DISTINCT master_id) AS total_users,

        COUNT(
            DISTINCT CASE
                WHEN engaged_session = 1
                THEN master_id
            END
        ) AS active_users,

        SUM(
            CASE
                WHEN row_type IN (
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
                WHEN engaged_session = 1
                THEN 1
                ELSE 0
            END
        ) AS engaged_sessions

    FROM activity
    GROUP BY
        activity_date,
        activity_year,
        activity_month,
        business_line,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage
),

-- ────────────────────────────────────────────────────────────────
-- One row per session (MAX for per-row flags/counts) so browsing
-- metrics aren't multiplied by the number of rows in a session.
-- ────────────────────────────────────────────────────────────────
session_grain AS (
    SELECT
        activity_date,
        activity_year,
        activity_month,
        business_line,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,
        ga_session_id,
        master_id,

        MAX(engaged_session)          AS engaged_session,
        MAX(logged_in_during_session) AS logged_in_during_session,

        MAX(COALESCE(unique_pdp_view_count, 0))        AS unique_pdp_view_count,
        MAX(COALESCE(unique_plp_view_count, 0))        AS unique_plp_view_count,
        MAX(COALESCE(unique_search_count, 0))          AS unique_search_count,
        MAX(COALESCE(unique_products_atc, 0))          AS unique_products_atc,
        MAX(COALESCE(cart_value_atc, 0))               AS cart_value_atc,
        MAX(COALESCE(engagement_score_session, 0))     AS engagement_score_session,
        MAX(COALESCE(session_duration_seconds, 0))     AS session_duration_seconds,
        MAX(COALESCE(unique_brand_count_lists, 0))     AS unique_brand_count_lists,
        MAX(COALESCE(unique_brand_count_pdp, 0))       AS unique_brand_count_pdp,
        MAX(COALESCE(unique_category_count_lists, 0))  AS unique_category_count_lists,
        MAX(COALESCE(unique_category_count_pdp, 0))    AS unique_category_count_pdp,
        MAX(COALESCE(unique_brand_count_search, 0))    AS unique_brand_count_search,
        MAX(COALESCE(unique_category_count_search, 0)) AS unique_category_count_search,
        MAX(add_to_cart)          AS add_to_cart,
        MAX(visited_cart)         AS visited_cart,
        MAX(visited_checkout)     AS visited_checkout,
        MAX(purchased_GA4)        AS purchased_GA4,
        MAX(most_browsed_category) AS most_browsed_category,
        MAX(most_browsed_brand)    AS most_browsed_brand

    FROM activity
    GROUP BY
        activity_date,
        activity_year,
        activity_month,
        business_line,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,
        ga_session_id,
        master_id
),

engagement_metrics AS (
    SELECT
        activity_date,
        activity_year,
        activity_month,
        business_line,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage,

        COUNT(DISTINCT ga_session_id)                AS ga4_sessions,

        AVG(CAST(engagement_score_session AS FLOAT)) AS avg_engagement_score,
        SUM(engagement_score_session)                AS total_engagement_score,
        SUM(session_duration_seconds)                AS total_session_duration,
        SUM(CASE WHEN logged_in_during_session = 1
            THEN 1 ELSE 0 END)                       AS sessions_logged_in,

        SUM(unique_pdp_view_count)                   AS unique_pdp_views,
        SUM(unique_plp_view_count)                   AS unique_plp_views,

        SUM(unique_search_count)                     AS total_searches,
        SUM(CASE WHEN unique_search_count > 0
            THEN 1 ELSE 0 END)                       AS sessions_with_search,

        SUM(add_to_cart)                             AS sessions_with_atc,
        SUM(unique_products_atc)                     AS total_products_atc,
        SUM(cart_value_atc)                          AS cart_value_atc,
        SUM(CASE WHEN visited_cart = 1
            THEN 1 ELSE 0 END)                       AS sessions_visited_cart,
        SUM(CASE WHEN visited_checkout = 1
            THEN 1 ELSE 0 END)                       AS sessions_visited_checkout,
        SUM(CASE WHEN purchased_GA4 = 1
            THEN 1 ELSE 0 END)                       AS sessions_with_purchase,

        SUM(unique_brand_count_lists)                AS brands_browsed_lists,
        SUM(unique_brand_count_pdp)                  AS brands_browsed_pdp,
        SUM(unique_category_count_lists)             AS categories_browsed_lists,
        SUM(unique_category_count_pdp)               AS categories_browsed_pdp,
        SUM(unique_brand_count_search)               AS brands_browsed_search,
        SUM(unique_category_count_search)            AS categories_browsed_search,

        MAX(most_browsed_category)                   AS most_browsed_category,
        MAX(most_browsed_brand)                      AS most_browsed_brand

    FROM session_grain
    GROUP BY
        activity_date,
        activity_year,
        activity_month,
        business_line,
        primary_segment,
        customer_maturity,
        session_substage,
        order_substage
)

SELECT
    k.activity_date,
    k.activity_year,
    k.activity_month,
    k.business_line,
    k.primary_segment,
    k.customer_maturity,
    k.session_substage,
    k.order_substage,

    -- base-aligned KPIs (tie out to base_query.sql)
    k.sales_npbe,
    k.orders,
    k.total_users,
    k.active_users,
    k.total_sessions,
    k.engaged_sessions,

    -- engagement-specific metrics
    COALESCE(e.ga4_sessions, 0)                AS ga4_sessions,
    e.avg_engagement_score,
    COALESCE(e.total_engagement_score, 0)      AS total_engagement_score,
    COALESCE(e.total_session_duration, 0)      AS total_session_duration,
    COALESCE(e.sessions_logged_in, 0)          AS sessions_logged_in,
    COALESCE(e.unique_pdp_views, 0)            AS unique_pdp_views,
    COALESCE(e.unique_plp_views, 0)            AS unique_plp_views,
    COALESCE(e.total_searches, 0)              AS total_searches,
    COALESCE(e.sessions_with_search, 0)        AS sessions_with_search,
    COALESCE(e.sessions_with_atc, 0)           AS sessions_with_atc,
    COALESCE(e.total_products_atc, 0)          AS total_products_atc,
    COALESCE(e.cart_value_atc, 0)              AS cart_value_atc,
    COALESCE(e.sessions_visited_cart, 0)       AS sessions_visited_cart,
    COALESCE(e.sessions_visited_checkout, 0)   AS sessions_visited_checkout,
    COALESCE(e.sessions_with_purchase, 0)      AS sessions_with_purchase,
    COALESCE(e.brands_browsed_lists, 0)        AS brands_browsed_lists,
    COALESCE(e.brands_browsed_pdp, 0)          AS brands_browsed_pdp,
    COALESCE(e.categories_browsed_lists, 0)    AS categories_browsed_lists,
    COALESCE(e.categories_browsed_pdp, 0)      AS categories_browsed_pdp,
    COALESCE(e.brands_browsed_search, 0)       AS brands_browsed_search,
    COALESCE(e.categories_browsed_search, 0)   AS categories_browsed_search,
    e.most_browsed_category,
    e.most_browsed_brand

FROM daily_kpis k

LEFT JOIN engagement_metrics e
       ON k.activity_date = e.activity_date

      AND (
            k.business_line = e.business_line
            OR (k.business_line IS NULL AND e.business_line IS NULL)
          )

      AND (
            k.primary_segment = e.primary_segment
            OR (k.primary_segment IS NULL AND e.primary_segment IS NULL)
          )

      AND (
            k.customer_maturity = e.customer_maturity
            OR (k.customer_maturity IS NULL AND e.customer_maturity IS NULL)
          )

      AND (
            k.session_substage = e.session_substage
            OR (k.session_substage IS NULL AND e.session_substage IS NULL)
          )

      AND (
            k.order_substage = e.order_substage
            OR (k.order_substage IS NULL AND e.order_substage IS NULL)
          );
