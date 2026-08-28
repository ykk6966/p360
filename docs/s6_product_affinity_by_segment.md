# S6 · Product affinity by segment — build guide

Source SQL: [`sql/s6_browsing_affinity.sql`](../sql/s6_browsing_affinity.sql)
DAX measures: [`dax/s6_product_affinity_by_segment.dax`](../dax/s6_product_affinity_by_segment.dax)

## 1. Load the data

Import the SQL view's output as a table named **`Browsing Affinity`**
(session-grain: `activity_date`, `Category`, `primary_segment`,
`customer_maturity`, `New_ret`, `business_line`, `LC_Channel`,
`device_type`, `Store`, `sessions`, `engaged_sessions`, `orders`, `NPBE`).

If you already have a Date table marked as such in the model, relate
`'Date'[Date]` (1) → `'Browsing Affinity'[activity_date]` (*). If not, use
the `Date` calculated table at the bottom of the `.dax` file.

## 2. Add the measures

Paste every measure from `dax/s6_product_affinity_by_segment.dax` into the
`Browsing Affinity` table. Read the comments at the top of each section —
they explain what each measure is for before you paste it.

Key idea for the **Index** tab: it's a ratio of two rates —

```
index = (segment's orders-per-session rate for the category)
        ÷ (everyone's orders-per-session rate for the category)
```

Both rates use *that population's sessions across every category* as the
denominator (not just the sessions for the category in the current cell),
so `ALL('Browsing Affinity'[Category])` / `ALL('Browsing Affinity'[primary_segment])`
are load-bearing — don't drop them.

> This table has no `master_id`, so "rate" here means *share of sessions*,
> not *share of distinct customers*. If the business wants a strictly
> customer-grain version of this visual later, it needs a different,
> customer-grain source — this table can't produce it.

## 3. Build the tab switcher

**Modeling → New parameter → Fields**, and add these five measures in this
order:

1. `S6 Affinity Index`
2. `S6 NPBE`
3. `S6 Orders`
4. `S6 Share of NPBE`
5. `S6 Δ Share YoY · R7`

This creates a small table (e.g. `S6 Metric`) with a Fields column. Rename
the display values to match the mock's tab labels: **Index**, **NPBE**,
**Orders**, **Share of NPBE**, **Δ Share YoY · R7**.

Add a slicer bound to `S6 Metric`, single-select, styled as a horizontal
tile/pill list so it reads as tabs (`Format visual → Slicer settings →
Style → Tile`).

## 4. Build the matrix

- Insert a **Matrix** visual.
- **Rows**: `Browsing Affinity[Category]`
- **Columns**: `Browsing Affinity[primary_segment]`
- **Values**: the `S6 Metric` field parameter's Fields column (this is
  what makes the matrix values change as the tab slicer changes)
- Custom-sort `primary_segment` to a fixed order (Planner, Splurger,
  Deadline, …) via a sort-by column if the source order isn't already
  right, and likewise sort `Category` if you want a fixed row order rather
  than alphabetical.
- Number format on the Values cells: `0.0"×"`.
- **Format visual → Row headers / Column headers → Subtotals → off.** A
  total row/column collapses numerator and denominator to the same
  population, so the "index" there isn't a meaningful number.

## 5. Conditional formatting (Index tab)

No extra DAX — use the built-in diverging color scale:

**Format visual → Cell elements → Background color → Format by: Field
value → Field: `S6 Affinity Index`** (or the field-parameter value while
the Index tab is selected) **→ enable Diverging**:

| Stop | Type | Value | Color |
|---|---|---|---|
| Minimum | Custom value | `0.5` | pink, e.g. `#F2B8B5` |
| Center | Number | `1` | grey/white, e.g. `#F1F1F1` |
| Maximum | Custom value | `3` | green, e.g. `#1E7145` |

Tune the min/max to the actual spread of index values once real data is
loaded — the mock shows roughly 0.6×–3.1×, hence the 0.5/3 bounds above.

## 6. Explanatory text boxes

The two callout boxes above the table ("Read a number like this…" and "How
we calculate it…") are static text boxes — they document the metric, they
don't need to react to filters. Reuse the copy from the mock as-is.
Optional nice-to-have: swap the worked numbers in "Read a number like
this…" for `[S6 Affinity Index Label]` / `[S6 Affinity Callout Text]`
measures pinned to a specific example cell (e.g. via a bookmark on the
current top cell), so the example stays truthful as data refreshes —
skip this for v1 and keep the text static.

## 7. Legend

Three static swatches + labels under the matrix: dark/light green =
"over-indexes", grey = "~average", pink = "under-indexes" — this just
mirrors the diverging color scale's three zones from step 5 and doesn't
need its own measure.
