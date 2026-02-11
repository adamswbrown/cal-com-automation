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
