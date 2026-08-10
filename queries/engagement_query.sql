WITH base AS (
    SELECT 
        activity_date,
        YEAR(activity_date)  AS activity_year,
        MONTH(activity_date) AS activity_month,

        intent_level_behavioral,
        business_line,
        LC_Channel,
        device_type,
        Store,
        Operating_system,
        landing_page_type,
        exit_page_type,

        ga_session_id,
        f.master_id,
        OrderNumber,
        npb_ordered,
        engaged_session,
        unique_pdp_view_count,
        unique_plp_view_count,
        unique_brand_count_lists,
        unique_brand_count_pdp,
        unique_category_count_lists,
        unique_category_count_pdp,
        unique_brand_count_search,
        unique_category_count_search,
        most_browsed_category,
        most_browsed_brand,
        cart_value_atc,
        engagement_score_session,
        s.primary_segment,

        unique_search_count,
        add_to_cart,
        visited_cart,
        visited_checkout,
        purchased_GA4,
        unique_products_atc,
        session_duration_seconds,
        logged_in_during_session

    FROM [dbo].[fct_customer_activity_agg] f
    JOIN segment_customer_snapshot s
        ON f.master_id = s.master_id
        --AND f.activity_date = s.snapshot_date
    WHERE has_behavioral_data = 1 and row_type <> 'pre_ga4_order' 
     -- AND activity_date >= DATEADD(YEAR, -2, CAST(GETDATE() AS DATE))
),

-- ════════════════════════════════════════════════════════════════
-- FIX: collapse multi-row sessions to ONE row per session BEFORE
-- aggregating — use MAX for per-row flags/counts, not SUM
-- ════════════════════════════════════════════════════════════════
session_grain AS (
    SELECT
        activity_date,
        activity_year,
        activity_month,
        ga_session_id,
        master_id,

        -- dimensions: assume stable within a session, take any value (MAX)
        MAX(intent_level_behavioral)  AS intent_level_behavioral,
        MAX(business_line)            AS business_line,
        MAX(LC_Channel)               AS LC_Channel,
        MAX(device_type)              AS device_type,
        MAX(Store)                    AS Store,
        MAX(Operating_system)         AS Operating_system,
        MAX(landing_page_type)        AS landing_page_type,
        MAX(exit_page_type)           AS exit_page_type,
        MAX(primary_segment)          AS primary_segment,

        MAX(engaged_session)          AS engaged_session,
        MAX(logged_in_during_session) AS logged_in_during_session,

        -- ORDERS/REVENUE — orders/revenue rows are typically distinct per order
        -- number, so keep as-is via SUM/DISTINCT at final aggregation, not here.
        -- (unique_pdp_view_count etc ARE the fix target)

        MAX(COALESCE(unique_pdp_view_count, 0))       AS unique_pdp_view_count,
        MAX(COALESCE(unique_plp_view_count, 0))       AS unique_plp_view_count,
        MAX(COALESCE(unique_search_count, 0))         AS unique_search_count,
        MAX(COALESCE(unique_products_atc, 0))         AS unique_products_atc,
        MAX(COALESCE(cart_value_atc, 0))               AS cart_value_atc,
        MAX(COALESCE(engagement_score_session, 0))    AS engagement_score_session,
        MAX(COALESCE(session_duration_seconds, 0))    AS session_duration_seconds,
        MAX(COALESCE(unique_brand_count_lists, 0))     AS unique_brand_count_lists,
        MAX(COALESCE(unique_brand_count_pdp, 0))       AS unique_brand_count_pdp,
        MAX(COALESCE(unique_category_count_lists, 0))  AS unique_category_count_lists,
        MAX(COALESCE(unique_category_count_pdp, 0))    AS unique_category_count_pdp,
        MAX(COALESCE(unique_brand_count_search, 0))    AS unique_brand_count_search,
        MAX(COALESCE(unique_category_count_search, 0)) AS unique_category_count_search,
        MAX(add_to_cart)      AS add_to_cart,
        MAX(visited_cart)     AS visited_cart,
        MAX(visited_checkout) AS visited_checkout,
        MAX(purchased_GA4)    AS purchased_GA4,
        MAX(most_browsed_category) AS most_browsed_category,
        MAX(most_browsed_brand)    AS most_browsed_brand,

        -- orders/revenue — keep distinct-order-safe via a separate rollup
        COUNT(DISTINCT OrderNumber)     AS session_orders,
        SUM(COALESCE(npb_ordered, 0))  AS session_npbe   -- revisit if npb_ordered also repeats per row; if so, switch to MAX per OrderNumber first

    FROM base
    GROUP BY activity_date, activity_year, activity_month, ga_session_id, master_id
),

engagement_agg AS (
    SELECT
        activity_date,
        activity_year,
        activity_month,

        intent_level_behavioral,
        business_line,
        LC_Channel,
        device_type,
        Store,
        Operating_system,
        landing_page_type,
        exit_page_type,
        primary_segment,
        --master_id,
        --engaged_session,
        -- VOLUME
        COUNT(DISTINCT ga_session_id)            AS sessions,
        COUNT(DISTINCT master_id)                AS customers,
        COUNT(DISTINCT CASE WHEN engaged_session = 1
              THEN master_id END)                AS active_users,

        -- ORDERS & REVENUE
        SUM(session_orders)                      AS orders_count,
        SUM(session_npbe)                        AS npb_ordered,

        -- ENGAGEMENT
        SUM(CASE WHEN engaged_session = 1
            THEN 1 ELSE 0 END)                   AS engaged_sessions,
        AVG(CAST(engagement_score_session AS FLOAT)) AS avg_engagement_score,
        SUM(engagement_score_session)            AS total_engagement_score,
        SUM(session_duration_seconds)            AS total_session_duration,
        SUM(CASE WHEN logged_in_during_session = 1
            THEN 1 ELSE 0 END)                   AS sessions_logged_in,

        -- BROWSING DEPTH — now correctly one MAX value per session, summed across sessions
        SUM(unique_pdp_view_count)               AS unique_pdp_views,
        SUM(unique_plp_view_count)                AS unique_plp_views,

        -- SEARCH
        SUM(unique_search_count)                  AS total_searches,
        SUM(CASE WHEN unique_search_count > 0
            THEN 1 ELSE 0 END)                   AS sessions_with_search,

        -- ATC / CART
        SUM(add_to_cart)                          AS sessions_with_atc,
        SUM(unique_products_atc)                  AS total_products_atc,
        SUM(cart_value_atc)                       AS cart_value_atc,
        SUM(CASE WHEN visited_cart = 1
            THEN 1 ELSE 0 END)                   AS sessions_visited_cart,
        SUM(CASE WHEN visited_checkout = 1
            THEN 1 ELSE 0 END)                   AS sessions_visited_checkout,
        SUM(CASE WHEN purchased_GA4 = 1
            THEN 1 ELSE 0 END)                   AS sessions_with_purchase,

        -- BRAND & CATEGORY BROWSING
        SUM(unique_brand_count_lists)             AS brands_browsed_lists,
        SUM(unique_brand_count_pdp)                AS brands_browsed_pdp,
        SUM(unique_category_count_lists)           AS categories_browsed_lists,
        SUM(unique_category_count_pdp)             AS categories_browsed_pdp,
        SUM(unique_brand_count_search)              AS brands_browsed_search,
        SUM(unique_category_count_search)           AS categories_browsed_search,

        MAX(most_browsed_category)               AS most_browsed_category,
        MAX(most_browsed_brand)                  AS most_browsed_brand

    FROM session_grain --where master_id = 'c795029605acdb4f83e2fdfcdffe7ab30889603a069a46ec0e6f2daee3b2ecac'
    GROUP by  --master_id, engaged_session,
        activity_date, activity_year, activity_month,
        intent_level_behavioral, business_line, LC_Channel, device_type,
        Store, Operating_system, landing_page_type, exit_page_type, primary_segment
)

SELECT * FROM engagement_agg;
