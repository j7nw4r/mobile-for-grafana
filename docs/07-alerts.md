# 07 — Alerts and silences

Grafana's alerting system is unified across data sources via "Grafana-managed
alert rules" — rule definitions live in Grafana, the rule engine evaluates
them, results route through Grafana's embedded Alertmanager. This doc
covers how the app surfaces those alerts and how the silence flow works.

## Scope

In:

- **Listing** currently firing + pending alert instances.
- **Detail** view for a single alert (rule + matchers + history).
- **Silence creation** to suppress notifications for a window.
- **Silence listing** so the user can see what's currently silenced and
  expire silences early.

Out:

- Creating, updating, or deleting **alert rules**. Read-only.
- Contact points, notification policies, mute timings, templates. Read-only
  is also out — there's no useful phone UX for this and the visible
  data isn't operator-actionable.
- **Datasource-managed alerts** (e.g. Prometheus AlertManager). We only
  surface Grafana-managed rules.

## The two endpoints

There are two alert-listing endpoints in Grafana, and they return *different*
data. Both are needed.

| Endpoint | What it returns | When we use it |
| --- | --- | --- |
| `/api/prometheus/grafana/api/v1/alerts` | Rule engine state — every firing or pending instance under a Grafana-managed rule | Alerts tab list view |
| `/api/alertmanager/grafana/api/v2/alerts` | Notification pipeline state — same instances *plus* silenced/inhibited info | Alert detail (to show "this is currently silenced by …") |

The rule-engine endpoint is fast (single query, no Alertmanager round-trip)
and gives us the firing/pending state. The Alertmanager endpoint adds the
silenced/inhibited overlay. Using both lets us list quickly and enrich on
demand.

### Rule engine response shape

```json
{
  "status": "success",
  "data": {
    "alerts": [
      {
        "labels": {
          "alertname": "HighCPU",
          "instance": "host-1",
          "severity": "warning",
          "team": "platform"
        },
        "annotations": {
          "summary": "CPU > 90% on host-1",
          "runbook_url": "https://wiki.example.com/runbooks/cpu"
        },
        "state": "firing",
        "activeAt": "2026-05-15T14:23:01.234Z",
        "value": "92.4"
      }
    ]
  }
}
```

We decode this into `[AlertInstance]` (see `03-api-and-models.md`).

### Alertmanager response shape

```json
[
  {
    "labels": {"alertname":"HighCPU","instance":"host-1"},
    "annotations": {"summary":"CPU > 90% on host-1"},
    "startsAt": "2026-05-15T14:23:01.234Z",
    "endsAt":   "2026-05-15T14:33:01.234Z",
    "updatedAt": "2026-05-15T14:28:01.234Z",
    "status": {
      "state": "suppressed",
      "silencedBy": ["abc-def-silence-id"],
      "inhibitedBy": []
    }
  }
]
```

We use `status.silencedBy[]` to enrich the detail view with a "Silenced by
<comment>" badge that links to the silence detail.

## Alerts tab UI

```
┌────────────────────────────────────────┐
│  Alerts                       [↻]     │
│  ──────────────────────────────────    │
│  [ All ▾ ]  [ Critical ▾ ]             │ ← filters
│                                        │
│  🔴 HighCPU                     2/14    │ ← group header (alertname)
│                                        │
│    host-1   severity=warning           │
│    CPU > 90% on host-1                 │
│    firing for 5m                       │
│                                        │
│    host-3   severity=warning           │
│    CPU > 90% on host-3                 │
│    firing for 12m                      │
│                                        │
│  🟡 DiskSpaceLow              1/8     │
│                                        │
│    disk-2                              │
│    Disk < 20% free                     │
│    pending for 3m                      │
│                                        │
└────────────────────────────────────────┘
```

### Filters

- **State filter**: All / Firing / Pending. Default "All". Inactive instances
  are excluded by the endpoint itself.
- **Severity filter**: pulls distinct values from the `severity` label
  across the result set. "All", plus each distinct value. Default "All".

Both filters apply client-side after the fetch.

### Grouping

Group by `alertname` label. Each group header shows alertname + a
count of "firing / total" (where total = firing + pending in this group).

Within a group, sort by firing state first, then by `activeAt` descending
(most recent first).

The group's icon comes from the highest severity in the group:

| Severity label | Icon |
| --- | --- |
| `critical` | 🔴 (red circle) |
| `warning` | 🟡 (yellow circle) |
| `info` | 🔵 (blue circle) |
| (anything else / missing) | ⚪ (grey circle) |

We use real SF Symbols (`exclamationmark.circle.fill` colored per token),
not emojis — the table above is illustrative.

### Empty state

`ContentUnavailableView("No active alerts", systemImage: "checkmark.circle",
description: Text("Nothing is firing or pending right now."))`.

## Alert detail UI

Tapping an instance opens a detail screen:

```
┌────────────────────────────────────────┐
│  ← HighCPU on host-1                   │
│  ──────────────────────────────────    │
│                                        │
│  🔴 FIRING for 12m                     │
│                                        │
│  CPU > 90% on host-1                   │ ← summary annotation
│                                        │
│  Labels                                │
│  • alertname:  HighCPU                 │
│  • instance:   host-1                  │
│  • severity:   warning                 │
│  • team:       platform                │
│                                        │
│  Annotations                           │
│  • summary:     CPU > 90% on host-1    │
│  • runbook:     https://…  [Open]      │
│                                        │
│  Last value: 92.4                      │
│                                        │
│  Rule                                  │
│  ──────────────────────────────────    │
│  CPU > 90% on host-1                   │
│  Expression:                           │
│    avg by (instance) (cpu_usage) > 90  │
│  For: 5m                               │
│  Folder: Platform / Host alerts        │
│                                        │
│  ──────────────────────────────────    │
│  [ Silence this alert... ]             │
│                                        │
└────────────────────────────────────────┘
```

### Data sources for the detail screen

- The `AlertInstance` from the list.
- Enriched with status from `/api/alertmanager/grafana/api/v2/alerts` (only
  for the silenced/inhibited overlay).
- The matching `AlertRule` from `/api/prometheus/grafana/api/v1/rules`
  (rule expression + `for` duration + folder).

The rule lookup matches on `labels.alertname` + rule group. There can in
theory be two rules with the same alertname; we show the first match and
display the group in the detail to disambiguate.

### "Open runbook"

If `annotations.runbook_url` is set, render an "Open" button next to it
that opens the URL in Safari (`SFSafariViewController`).

### Currently silenced

If the detail-screen enrichment shows the alert is `suppressed` and has
`silencedBy[]` entries:

```
ℹ️  Silenced by "ack from oncall"
    Expires in 47m   [ View silence ]
```

"View silence" navigates to the silence detail screen.

## Silence creation

The "Silence this alert..." action opens a sheet:

```
┌────────────────────────────────────────┐
│  Silence HighCPU on host-1             │
│  ──────────────────────────────────    │
│                                        │
│  Duration                              │
│  [ 1 hour ▾ ]                          │
│                                        │
│  Matchers                              │
│  ☑ alertname = HighCPU                 │
│  ☑ instance  = host-1                  │
│  ☐ severity  = warning                 │
│  ☐ team      = platform                │
│                                        │
│  (Uncheck a label to silence a wider   │
│   set — e.g. all "HighCPU" instances.) │
│                                        │
│  Comment                               │
│  [ ack from oncall                  ]  │
│                                        │
│  [ Cancel ]      [   Silence    ]      │
└────────────────────────────────────────┘
```

### Duration presets

- 15 minutes
- 1 hour (default — matches the operator's "I'll look at this after
  this meeting" use case)
- 4 hours
- 24 hours
- Custom — opens a date+time picker for the end time

`startsAt` is always "now" (no scheduled silences in v1).

### Matchers

Default: every label of the alert instance pre-checked. Unchecking
broadens the silence (a silence with only `alertname=HighCPU` checked
silences *all* HighCPU instances, not just the one we came from).

We don't allow editing label values in v1 — only checking/unchecking. The
user can add free-form matchers via the Grafana web UI if they need to;
phone is for quick silences, not policy management.

### Comment

Required (default placeholder reflects the most common use). The string
gets stored verbatim in the silence record's `comment` field. The
`createdBy` field is set to the current user's `login` from `/api/user`.

### POST body

```json
POST /api/alertmanager/grafana/api/v2/silences
Content-Type: application/json

{
  "matchers": [
    {"name":"alertname","value":"HighCPU","isRegex":false,"isEqual":true},
    {"name":"instance","value":"host-1","isRegex":false,"isEqual":true}
  ],
  "startsAt": "2026-05-15T14:30:00Z",
  "endsAt":   "2026-05-15T15:30:00Z",
  "createdBy": "alice",
  "comment": "ack from oncall"
}
```

Response: `{"silenceID": "abc-def-…"}`.

### Permission check

Silencing requires Editor role (or appropriate RBAC). We don't know the
token's permissions up front, so:

- Always render the "Silence" button.
- On error: if response is 403 with `permissionDenied`, show a non-modal
  toast: "Your account doesn't have permission to silence alerts."
- After a 403 we remember "this server's credential can't silence" in
  the in-memory `ServerContext` and hide the button for the rest of
  the session (saves the user re-tapping it).

We don't cache this permission status persistently — a user might rotate
to a new token with broader rights and we want them to see it
immediately.

## Silence list

A secondary screen accessed from a Settings entry "Active silences" (and
linked from "View silence" in alert detail).

```
┌────────────────────────────────────────┐
│  ← Active silences                     │
│  ──────────────────────────────────    │
│                                        │
│  HighCPU + 1 more matcher              │
│  ack from oncall                       │
│  Expires in 47m  •  by alice           │
│  [ Expire now ]                        │
│                                        │
│  DiskSpaceLow                          │
│  weekly maintenance                    │
│  Expires in 5d  •  by bob              │
│  [ Expire now ]                        │
│                                        │
└────────────────────────────────────────┘
```

Endpoint: `GET /api/alertmanager/grafana/api/v2/silences`.

Filter to `status.state == "active"` (pending and expired silences are not
shown by default).

"Expire now" issues `DELETE /api/alertmanager/grafana/api/v2/silence/{id}`.
The row animates out on success.

## Acknowledgements

There is no real "ack" in Grafana alerting. The closest concept is a
short-duration silence. The detail screen's "Silence this alert..." action
defaults to 1 hour, which is the "ack until I get back to this" duration.

We considered exposing a one-tap "Ack" button that creates a 1-hour
silence with only `alertname` and `instance` matchers — saving two taps.
We're not doing it in v1 because:

- "Ack" implies acknowledgement-without-suppression in most alerting
  vocabularies, which isn't what's actually happening.
- The two-tap path is honest about what the action is.

The UI uses the word "Silence", not "Ack". The 1-hour default is the
nudge toward the ack-style use case.

## Rule-only view (no instance to silence)

For inactive rules (firing zero instances) we still expose a "Rules"
sub-tab in the alerts tab — same UI as the alert detail's Rule
section, but listed standalone. This is the operator's "what alerts
*exist* in this Grafana?" view.

Endpoint: `GET /api/prometheus/grafana/api/v1/rules`. Filter the
response to `data.groups[].rules[]` where `type == "alerting"`. Show:

```
┌────────────────────────────────────────┐
│  Rules                       [↻]      │
│  ──────────────────────────────────    │
│                                        │
│  Platform / Host alerts                │
│    HighCPU         ✓ ok                │
│    HighMemory      ⚠️ pending (host-2) │
│    DiskFailed      🔴 firing (disk-1)  │
│                                        │
│  Platform / Cluster                    │
│    NodeNotReady    ✓ ok                │
│                                        │
└────────────────────────────────────────┘
```

Rule rows show current state. Tap → same alert-detail screen as the
firing instance list (if there's a firing instance, that instance is the
"hero"; otherwise the screen shows just the rule definition with no
instance section).

## Refresh policy

- Pull-to-refresh on the alerts list.
- No auto-refresh in v1.
- After a silence is created, the relevant rows update locally without
  re-fetching (we know what we just did).
- After "Expire now", same.

## Tests

`GrafanaViewerTests/Alerts/` covers:

- Parsing the two endpoint responses (canonical Grafana 11.x fixtures).
- Matcher derivation from labels (every label pre-checked).
- `startsAt`/`endsAt` ISO-8601 formatting for the silence POST body.
- 403 handling toggles the in-memory "can't silence" flag.
- Severity → icon mapping for the canonical strings + the unknown case.

---

Onward: [`08-search-starred-annotations.md`](08-search-starred-annotations.md).
