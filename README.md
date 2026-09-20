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
