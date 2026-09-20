# cal-com-automation

## Viewing Azure Function Logs

### Live logs (while webhook runs)

1. In Azure Portal, open your Function App.
2. Go to `Functions` -> `cal-automation` -> `Monitor` -> `Log stream`.
3. Trigger a Cal.com webhook and watch log lines appear in real time.

### Historical logs in Application Insights

1. In your Function App, open `Application Insights` (linked resource).
2. Open `Logs` and run one of the queries below.

Recent structured events:

```kusto
traces
| where timestamp > ago(24h)
| where message has "\"event\""
| project timestamp, severityLevel, message
| order by timestamp desc
```

Filter by booking UID:

```kusto
traces
| where timestamp > ago(24h)
| where message has "bookingUid"
| where message has "YOUR_BOOKING_UID"
| project timestamp, severityLevel, message
| order by timestamp asc
```

Errors only:

```kusto
traces
| where timestamp > ago(24h)
| where severityLevel >= 3
| project timestamp, severityLevel, message
| order by timestamp desc
```

### Local logs

If running locally, start the function host and watch the terminal output:

```bash
func start
```

## One-click Logs Dashboard (Workbook)

A deployable Azure Monitor workbook is included at:

- `infra/azure/cal-automation-logs-workbook.bicep`

It provides:

1. Recent structured events
2. Errors by event/status
3. Failure details (including `httpStatus` and `responseBody`)
4. Grouping by `invocationId`

### Deploy the workbook

1. Find your Application Insights resource ID:

```bash
az monitor app-insights component show \
  --app cal-booking-automation \
  --resource-group cal-booking-automation_group-b946 \
  --query id -o tsv
```

2. Deploy the workbook template:

```bash
az deployment group create \
  --resource-group cal-booking-automation \
  --template-file infra/azure/cal-automation-logs-workbook.bicep \
  --parameters appInsightsResourceId=<APP_INSIGHTS_RESOURCE_ID> \
               workbookName=cal-automation-logs \
               workbookDisplayName="Cal Automation Logs Dashboard"
```

3. Open in Azure Portal: go to `Azure Monitor` -> `Workbooks`, then open `Cal Automation Logs Dashboard`.

### Optional: pin to Azure Dashboard

From the workbook, use the `Pin` action on each visualization to add them to a shared Azure Portal dashboard.

## Guest Reconciliation

`cal-reconcile` runs hourly and closes gaps the webhook missed — dropped
deliveries, silently failed API calls, and rule changes that were not applied
retroactively.

Each run lists upcoming bookings starting within 30 days, compares their guests
against the rules in `Modules/CalGuestRules`, and:

- adds missing guests when the booking is more than 24 hours away
- writes a `Needs action` row to Notion and @-mentions Adam when it is closer
  than that, since adding a guest re-notifies every attendee

Results land in the `Cal Guest Reconciliation` database under ⚙️ Operations.

### Required app settings

| Setting | Purpose |
|---|---|
| `CAL_API_KEY` | Cal.com API key (already set) |
| `NOTION_TOKEN` | Notion integration token |
| `NOTION_DB_ID` | The Cal Guest Reconciliation database id |
| `NOTION_MENTION_USER_ID` | Notion user to @-mention |
| `RECONCILE_WINDOW_DAYS` | Optional, default 30 |
| `RECONCILE_AUTO_ADD_THRESHOLD_HOURS` | Optional, default 24 |

### Changing who gets added

Edit the rules table in `Modules/CalGuestRules/CalGuestRules.psm1`. Both the
webhook and the reconciler read it, so there is one place to change and no
opportunity for the two to drift.

### Running the tests

```bash
pwsh -NoProfile -c "Invoke-Pester tests/ -Output Detailed"
```

### Reconciler logs

```kusto
traces
| where timestamp > ago(7d)
| where message has "Reconcile"
| extend parsed = parse_json(message)
| project timestamp, event = tostring(parsed.event), bookingUid = tostring(parsed.bookingUid),
          missing = tostring(parsed.missingGuests), hoursUntilStart = todouble(parsed.hoursUntilStart)
| order by timestamp desc
```

## Guest rules live in Notion

The rules that decide who gets added are the `Cal Guest Rules` database under
⚙️ Operations, not code. Both functions read it, cached for the life of the
worker instance — a change goes live on the next cold start.

| Property | Purpose |
|---|---|
| `Rule` | Name, for humans |
| `Active` | Only ticked rows are evaluated |
| `Match Type` | `Always`, `Slug contains`, `Slug exact`, `Customer contains` |
| `Match` | The term to compare. Blank for `Always`. |
| `Guests` | Multi-select of email addresses |
| `Notes` | Why the rule exists |

### Guest display names

Names are derived from the address, so you only pick the email:

```
luke.lloyd@altra.cloud  ->  Luke Lloyd
```

For an address that does not follow `firstname.lastname`, write the option as
`Partner Desk <info@partner.com>` instead.

### When Notion is unavailable

Both functions fall back to the built-in rules in
`Modules/CalGuestRules/CalGuestRules.psm1`, which are kept identical to the
seeded Notion rows — so a fallback is a no-op rather than a behaviour change.
The fallback logs `RulesFellBack` at Error level and attempts a Notion alert.

A malformed row is skipped, not fatal: one typo drops that rule, the rest still
apply. An unknown match type never matches, so a typo adds nobody rather than
everybody.

## Fallback alerting

The Notion row and comment is the primary alert. It cannot report on Notion
being down, and it cannot report on the function not running at all — which
looks identical to everything being fine.

`infra/azure/cal-automation-alerts.bicep` deploys two rules reading Application
Insights, which the functions write to before touching Notion:

| Rule | Fires when |
|---|---|
| `cal-automation-errors` | Any Error-level log, `RulesFellBack`, `ReconcileFailed`, `GuestAddFailed` |
| `cal-automation-reconciler-silent` | No `ReconcileCompleted` in 3 hours |

The second is the dead-man switch, and the only thing that catches a broken
deploy or a disabled timer.

### Deploy the alerts

```bash
az deployment group create \
  --resource-group cal-booking-automation_group-b946 \
  --template-file infra/azure/cal-automation-alerts.bicep \
  --parameters appInsightsResourceId=<APP_INSIGHTS_RESOURCE_ID> \
               alertEmailAddress=adam@askadam.cloud
```
