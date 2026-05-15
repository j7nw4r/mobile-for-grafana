# 05 — Panels and charts

This doc enumerates the panel types we render in v1, how each maps onto
Swift Charts (or, where Swift Charts doesn't fit, a custom `Canvas` view),
and how thresholds, units, colors, and refresh behavior work.

## Panel types we support in v1

| Grafana type | On-device renderer | Data source |
| --- | --- | --- |
| `timeseries` | `TimeSeriesPanelView` (Swift Charts `LineMark` / `AreaMark`) | `TimeSeriesDecoder` |
| `stat` | `StatPanelView` (number + sparkline) | `TimeSeriesDecoder` |
| `gauge` | `GaugePanelView` (Canvas-drawn arc) | `TimeSeriesDecoder`, reduced |
| `bargauge` | `BarGaugePanelView` (`BarMark` rows) | `TimeSeriesDecoder`, reduced |
| `table` | `TablePanelView` (SwiftUI `Grid`) | `TableDecoder` |
| `logs` | `LogsPanelView` (`List` rows) | `LogStreamDecoder` |

## Panel types we explicitly *don't* render in v1

If we encounter one of these we render a placeholder card with the panel
title and "Unsupported panel type: <type>". No crash, no silent skip.

| Type | Why not |
| --- | --- |
| `heatmap` | Requires bucketed 2D data; significant Swift Charts work |
| `geomap` | MapKit integration is its own feature |
| `node-graph` | Force-directed layout, distraction-set in scope |
| `traces` | Requires Tempo integration |
| `alert-list` | Phone-screen-unfriendly; Alerts tab covers the use case |
| `news` | Cosmetic, low utility on phone |
| `candlestick` | Rare outside finance dashboards |
| `dashboard` (links list) | Cosmetic |
| `row` | Layout element; we flatten the grid anyway |

A `row` panel (Grafana's collapsible row separator) is treated specially:
we render it as a section header in the panel list rather than as a card.

## Panel renderer protocol

Each panel view is a SwiftUI view fed by a decoded model + the panel
metadata:

```swift
struct PanelHeader: View {
  let title: String
  let isLoading: Bool
  let error: String?
  let onRefresh: () -> Void
  // Renders title, optional spinner, optional error icon with tap-to-expand
}

struct TimeSeriesPanelView: View {
  let panel: Panel
  let data: TimeSeries
  // ... renders chart + legend
}
```

The container (`PanelCardView`) owns the chrome (border, header, error
state) and embeds the type-specific view.

## TimeSeries panel

Data model: `TimeSeries` (see `04-datasource-queries.md`).

SwiftUI Charts shape:

```swift
Chart {
  ForEach(data.series, id: \.name) { series in
    ForEach(series.points, id: \.time) { p in
      LineMark(
        x: .value("Time", p.time),
        y: .value(series.unit ?? "", p.value ?? .nan)
      )
      .foregroundStyle(by: .value("Series", series.name))
    }
  }
}
.chartXAxis { /* dynamic format based on time range */ }
.chartYAxis { /* unit-formatted ticks */ }
.chartLegend(position: .bottom, alignment: .leading)
```

Three concrete decisions:

1. **Line vs area.** Panel options has a `drawStyle` field (`line` / `bars`
   / `points`) and a `fillOpacity` field. v1: if `fillOpacity > 0`, use
   `AreaMark`; else `LineMark`. Other draw styles render as `LineMark`.
   The `bars` style is rare for time series; we punt.
2. **Stacked series.** Panel options has a `stacking` mode. v1: not
   supported — we render unstacked. Document this in the panel header as
   an "(unstacked view)" hint when we detect stacking is configured.
3. **Multiple Y axes.** Grafana supports left/right Y axes. v1: single
   Y axis only. Right-axis series use the same axis. Document.

### Legend

Below the chart. Shows series name + color swatch + last value (formatted
via the panel's unit). Tap a row to toggle that series' visibility — the
chart re-renders with the hidden series filtered out. Long-press copies
the series name to the clipboard.

### Hover / inspect

On a phone, hover doesn't exist; we use the "long press + drag" gesture:

```
[long-press on chart]
       │
       ▼
   Show a vertical RuleMark + bubble with timestamp + all series values at
   that timestamp (interpolated to the nearest sample).
       │
       ▼
   [user drags] → bubble follows finger
       │
       ▼
   [user lifts] → bubble dismisses
```

Swift Charts supports this via `chartGesture` and `chartXSelection` (iOS
17+).

### Annotations

If the dashboard has annotations enabled and we've fetched any in the
panel's time range, overlay them as `RuleMark`s at the right timestamps,
colored per the annotation type (alert annotations red, user annotations
blue). Detail in
[`08-search-starred-annotations.md`](08-search-starred-annotations.md).

## Stat panel

Big number + small sparkline. Data is the same `TimeSeries`, but we
reduce to one value for display.

```
┌────────────────────────────┐
│  CPU Usage          18.4%  │
│                            │
│     ╱╲      ╱╲             │  (sparkline of last N samples)
│  ╱╲╱  ╲╱╲╱╲╱  ╲╱╲╱         │
└────────────────────────────┘
```

Reduction:

- Panel options has a `reduceOptions.calcs[]` field — `["lastNotNull"]`,
  `["mean"]`, `["max"]`, etc. v1 supports `lastNotNull`, `mean`, `max`,
  `min`, `sum`, `count`. Default `lastNotNull`.
- If multiple series, render one "tile" per series in a vertical stack
  (matching Grafana's default).

Threshold coloring:

- Compute the reduced value.
- Walk `fieldConfig.defaults.thresholds.steps[]` in order; the matched
  step's `color` is the tile's text color (or background, per options).
- "Percentage" mode: divide by panel `max - min` first.

Sparkline:

- Use `LineMark` over the same time series.
- No axes, no legend, no grid — purely visual.
- Fixed height (~40pt). Color matches threshold.

## Gauge panel

Radial arc gauge. Swift Charts doesn't natively do gauges (`Gauge` exists
on watchOS / iOS 16+ but is limited). We draw it with `Canvas`:

```
       60
   40       80
20  ╭───╮     100
   ╰─ X ─╯
        45%
       value
```

Implementation:

```swift
struct GaugePanelView: View {
  let panel: Panel
  let value: Double
  let min: Double
  let max: Double
  let thresholds: Thresholds?

  var body: some View {
    GeometryReader { geo in
      Canvas { ctx, size in
        let center = CGPoint(x: size.width/2, y: size.height/2 + size.height*0.1)
        let radius = min(size.width, size.height*1.4) / 2 - 12
        let startAngle = Angle.degrees(180)
        let endAngle = Angle.degrees(360)
        // background track
        ctx.stroke(arc(center, radius, startAngle, endAngle), with: .color(.gray.opacity(0.2)), lineWidth: 14)
        // value arc
        let valueAngle = startAngle + (endAngle - startAngle) * normalize(value, min: min, max: max)
        ctx.stroke(arc(center, radius, startAngle, valueAngle), with: .color(thresholdColor(value)), lineWidth: 14)
      }
      // overlaid value + label text via SwiftUI Text in a ZStack
    }
  }
}
```

Reduction is identical to the stat panel.

If multiple series, render multiple gauges in a vertical or horizontal
arrangement (panel options `orientation`).

## BarGauge panel

Horizontal bars, one per series. Swift Charts `BarMark`:

```swift
Chart {
  ForEach(reducedSeries) { s in
    BarMark(
      x: .value("Value", s.value),
      y: .value("Series", s.name)
    )
    .foregroundStyle(thresholdColor(s.value))
  }
}
.chartXScale(domain: [panel.fieldConfig?.defaults.min ?? 0,
                       panel.fieldConfig?.defaults.max ?? autoMax])
```

Panel options decide LCD vs gradient vs basic visualization. v1: basic
only. Document.

## Table panel

SwiftUI `Grid` with one column per `TableData.Column`:

```swift
Grid(alignment: .leading) {
  // Header row
  GridRow {
    ForEach(data.columns, id: \.name) { Text($0.name).font(.caption).bold() }
  }
  // Body rows
  ForEach(0..<data.rowCount, id: \.self) { row in
    GridRow {
      ForEach(data.columns, id: \.name) { col in
        cellView(col, row)
      }
    }
  }
}
```

Cell rendering by column type:

| Column type | Cell view |
| --- | --- |
| `.time` | Date formatter, short style |
| `.number` | Unit formatter (see below); right-aligned |
| `.string` | `Text` |
| `.bool` | `Image(systemName: value ? "checkmark" : "xmark")` |

Wide tables on a phone are awkward. Strategy:

- Horizontal scroll inside the panel card.
- A "table" panel longer than 8 rows shows a "View full table" button that
  opens a full-screen modal.
- Column-width auto-sizes to content with a max of 40% panel width per
  column (so a single wide column doesn't crowd out the rest).

Field overrides (cell colors, value mappings) are parsed but not applied
in v1 — call out in the panel header as "(reduced view)" if overrides
exist.

## Logs panel

Loki only. `List` of log lines:

```
┌────────────────────────────────────────────────┐
│ 14:23:01.234  [INFO]  pod=api-7b9                │
│ User signed in: user_id=42                       │
├────────────────────────────────────────────────┤
│ 14:23:01.567  [WARN]  pod=api-7b9                │
│ Rate limit approaching for tenant=foo            │
└────────────────────────────────────────────────┘
```

Per line:

- Timestamp (HH:mm:ss.SSS, fixed width, monospaced).
- Level pill (color-coded: INFO grey, WARN amber, ERROR red, DEBUG faint).
- Selected labels — by default `pod` / `instance` / `service` if present.
- Body (the actual log line), monospaced, wrappable.

Tapping a line expands to a detail card showing all labels.

Performance: Loki query returns up to `maxLines` (default 1000). We render
all of them in a `LazyVStack` inside a `ScrollView`. Beyond ~5000 lines
SwiftUI rendering degrades; we document the `maxLines` cap and don't
support paginated loading in v1.

Search-within-logs is not in v1. Document.

## Thresholds + colors

`fieldConfig.defaults.thresholds` shape:

```json
{
  "mode": "absolute",
  "steps": [
    { "color": "green",  "value": null },
    { "color": "yellow", "value": 80 },
    { "color": "red",    "value": 95 }
  ]
}
```

Semantics: the step with the largest `value` ≤ the data value applies.
The `null`-valued step is the base (everything below the first numeric
threshold).

Color names Grafana uses, mapped to our color tokens:

| Grafana | Asset name | Notes |
| --- | --- | --- |
| `green` | `threshold.green` | Default OK |
| `yellow` | `threshold.yellow` | Default warn |
| `red` | `threshold.red` | Default critical |
| `orange` | `threshold.orange` | |
| `blue` | `threshold.blue` | Often used for "info" |
| `purple` | `threshold.purple` | |
| `dark-*` and `light-*` variants | Same hue, adjusted lightness | |
| `#abcdef` (hex) | Parsed directly | |

Colors are asset-catalog backed so dark/light mode work without code.

For timeseries series colors (not thresholded), Grafana auto-cycles
through a palette. v1: cycle through the same colors in our own palette
(8 colors), seeded by series name hash so the same series gets the same
color across refreshes.

## Unit formatting

Grafana's `unit` strings are a non-trivial catalog. We support the 12
most common in v1; others fall through to the bare number.

| Unit | Formatter | Example |
| --- | --- | --- |
| `none` / `short` | Compact with SI suffix | `12.4K`, `3.1M` |
| `bytes` | Binary IEC | `4.2 GiB` |
| `decbytes` | Decimal SI | `4.2 GB` |
| `bps`, `Bps` | Bits/Bytes per second | `1.2 Mbps` |
| `percent` | `12.4%` |
| `percentunit` | input × 100 → `%` | `0.124` → `12.4%` |
| `s` | Seconds, scaled (ms/µs/s/m/h) | `134 ms`, `2.4 s`, `1.3 h` |
| `ms` | Like `s` but input is ms | `134 ms`, `2.4 s` |
| `dateTimeAsIso` | ISO-8601 date | `2026-05-15T14:23` |
| `currencyUSD` | USD with locale | `$1,234.56` |

Unsupported units fall back to `short`. Document the fallback so users
know what they're getting.

Decimal places come from `fieldConfig.defaults.decimals` if set; else
the formatter's default (typically 1).

## Refresh

Three refresh paths:

| Trigger | Behavior |
| --- | --- |
| Pull-to-refresh on dashboard | Re-query *all* panels |
| Panel header refresh button | Re-query *this* panel |
| Time range change | Re-query all panels with new range |

We do **not** have:

- Auto-refresh (the dashboard's `refresh: "30s"` field is ignored in v1).
- Live streaming via WebSocket.
- Background refresh.

Document the trade-off: "If you want to see fresh data, pull to refresh."
This keeps the implementation simple and avoids battery surprises.

## Loading + error states

```
┌────────────────────────────┐
│  Panel title       (icon)  │
│ ────────────────────────── │
│                            │
│      [spinner]             │  ← loading
│                            │
└────────────────────────────┘

┌────────────────────────────┐
│  Panel title       ⚠️      │
│ ────────────────────────── │
│  Query error               │  ← error
│  parse error: …            │
│  [ Retry ]                 │
└────────────────────────────┘

┌────────────────────────────┐
│  Panel title               │
│ ────────────────────────── │
│       No data              │  ← empty
└────────────────────────────┘
```

Loading state is per-panel — a slow datasource doesn't block other
panels. Error state shows the server-provided error message + a retry
button. Empty state ("the query succeeded but returned no points") is
distinct from error.

## Tests

`GrafanaViewerTests/Panels/` covers:

- Threshold matching (boundary values, percentage mode, missing
  thresholds → default color).
- Unit formatter for each supported unit (one positive case + one edge:
  zero, negative, very small).
- TimeSeriesDecoder with the canonical Prometheus fixture, the "all nulls"
  case, and the "no `time` field" case.
- Stat panel reduction for each calc.

No snapshot testing in v1 — Swift Charts output is hard to snapshot
reliably and the maintenance cost is real. Visual diffs go through
TestFlight.

---

Onward: [`06-dashboards-and-variables.md`](06-dashboards-and-variables.md).
