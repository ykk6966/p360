# S6 · Product affinity by segment — build guide

Source SQL: [`sql/s6_browsing_affinity.sql`](../sql/s6_browsing_affinity.sql)
DAX measures: [`dax/s6_product_affinity_by_segment.dax`](../dax/s6_product_affinity_by_segment.dax)

## 1. Load the data

Import the SQL view's output as a table named **`browsing_affinity`**
(session-grain: `activity_date`, `Category`, `primary_segment`,
`customer_maturity`, `New_ret`, `business_line`, `LC_Channel`,
`device_type`, `Store`, `sessions`, `engaged_sessions`, `orders`, `NPBE`).

Add a Date table marked as such in the model, related
`'Date'[Date]` (1) → `'browsing_affinity'[activity_date]` (*). If you don't
have one, use the `Date` calculated table at the bottom of the `.dax` file.

## 2. Add the base measures

```
S6 Sessions          = SUM('browsing_affinity'[sessions])
S6 Engaged Sessions  = SUM('browsing_affinity'[engaged_sessions])
S6 Orders            = SUM('browsing_affinity'[orders])
S6 NPBE              = SUM('browsing_affinity'[NPBE])
```

## 3. Build the Browsing Affinity Index — session-based, not order-based

Since `Category = most_browsed_category`, the index measures where a
segment's **browsing sessions** land relative to everyone else — not a
purchase rate:

```
index = (segment's share of its own sessions in this category)
        ÷ (everyone's share of its own sessions in this category)
```

```dax
S6 Segment Sessions All Categories =
CALCULATE([S6 Sessions], REMOVEFILTERS('browsing_affinity'[Category]))

S6 Segment Category Browse Rate =
DIVIDE([S6 Sessions], [S6 Segment Sessions All Categories])

S6 Overall Category Sessions =
CALCULATE([S6 Sessions], REMOVEFILTERS('browsing_affinity'[primary_segment]))

S6 Overall Sessions All Categories =
CALCULATE(
    [S6 Sessions],
    REMOVEFILTERS('browsing_affinity'[Category]),
    REMOVEFILTERS('browsing_affinity'[primary_segment])
)

S6 Overall Category Browse Rate =
DIVIDE([S6 Overall Category Sessions], [S6 Overall Sessions All Categories])

S6 Browsing Affinity Index =
DIVIDE([S6 Segment Category Browse Rate], [S6 Overall Category Browse Rate])
```

**Debug before formatting.** Build the index matrix (Rows = `Category`,
Columns = `primary_segment`, Values = `[S6 Browsing Affinity Index]`) with
the measure formatted as **Decimal number, 2 decimal places** — not `x`
yet. The matrix **Total must read 1.00**. If it doesn't, there's a
filter-context bug in the `REMOVEFILTERS` calls above — stop and fix it
before doing anything else with this visual.

Once the Total checks out, switch the format string to `"0.0""x"""` and
apply conditional formatting (step 6).

## 4. NPBE % of Segment Sales

```dax
S6 Segment NPBE All Categories =
CALCULATE([S6 NPBE], REMOVEFILTERS('browsing_affinity'[Category]))

S6 NPBE % of Segment Sales =
DIVIDE([S6 NPBE], [S6 Segment NPBE All Categories])
```

Format: `0.0%`

## 5. NPBE per Session

No `master_id` in this table, so this is per-session, not per-customer:

```dax
S6 NPBE per Session = DIVIDE([S6 NPBE], [S6 Sessions])
```

Format: `$#,0`

## 6. Δ Share YoY · R7 (NPBE and Orders)

Trailing-7-day share vs. the same trailing-7-day window one year earlier,
in **percentage points** — multiply by 100, since the page displays
`+0.6 pp` / `-0.3 pp`, not `+0.006`.

```dax
S6 NPBE R7 =
VAR EndDate = MAX('Date'[Date])
RETURN CALCULATE([S6 NPBE], DATESINPERIOD('Date'[Date], EndDate, -7, DAY))

S6 Segment NPBE R7 All Categories =
CALCULATE([S6 NPBE R7], REMOVEFILTERS('browsing_affinity'[Category]))

S6 NPBE Share R7 = DIVIDE([S6 NPBE R7], [S6 Segment NPBE R7 All Categories])

S6 NPBE Share R7 LY =
CALCULATE([S6 NPBE Share R7], DATEADD('Date'[Date], -1, YEAR))

S6 Δ Share NPBE YoY pp =
([S6 NPBE Share R7] - [S6 NPBE Share R7 LY]) * 100
```

Repeat the same construction on `S6 Orders` for `S6 Δ Share Orders YoY pp`
(`S6 Orders R7`, `S6 Segment Orders R7 All Categories`, `S6 Order Share
R7`, `S6 Order Share R7 LY`).

Dynamic format for both: `"+0.0 ""pp"";-0.0 ""pp"";0.0 ""pp"""`

## 7. Layout — two visuals, no tab switcher

The metrics table shows all six measures at once (no field parameter, no
tabs, no label/callout text measures):

- `S6 NPBE`
- `S6 Orders`
- `S6 NPBE % of Segment Sales`
- `S6 NPBE per Session`
- `S6 Δ Share NPBE YoY pp`
- `S6 Δ Share Orders YoY pp`

The **index matrix is separate**:

- Rows: `browsing_affinity[Category]`
- Columns: `browsing_affinity[primary_segment]`
- Values: `[S6 Browsing Affinity Index]`

Verify the Total is `1.00` (Decimal number, 2 decimals) before switching
to `0.0x` formatting and applying the diverging heatmap:

**Format visual → Cell elements → Background color → Format by: Field
value → Field: `S6 Browsing Affinity Index` → enable Diverging:**

| Stop | Type | Value | Color |
|---|---|---|---|
| Minimum | Custom value | `0.5` | rust/pink |
| Center | Number | `1` | neutral/grey |
| Maximum | Custom value | `3` | green |

Turn off row/column subtotals on the index matrix — a total row/column
collapses numerator and denominator to the same population, so it isn't a
meaningful business number (the 1.00 check above is a build-time sanity
check, not something to ship in the visual).

## Not implemented (skipped per current design)

- Order-based `Segment Category Rate` / `Population Category Rate` (that
  was purchase propensity after browsing, not browsing share — dropped in
  favor of the session-based index above).
- Field parameter / tab switcher, `S6 Selected Metric`.
- Affinity label / callout text measures.

Revisit the field parameter only if the page later needs buttons/tabs to
switch between metrics instead of showing them all at once.
