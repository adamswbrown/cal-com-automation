# Cal.com Guest Reconciliation — Design

**Date:** 2026-09-20
**Status:** Approved for implementation
**Repo:** `cal-com-automation`

## Problem

The `cal-automation` webhook adds guests to a Cal.com booking when the booking is
created. It is the only mechanism that does so, and it has three failure modes with
no recovery path:

1. **Dropped webhooks.** If Cal.com fails to deliver, or the Function is cold and
   times out, the booking silently never gets its guests.
2. **Silent API failures.** The webhook returns HTTP 200 regardless of whether the
   Cal API call succeeded (`run.ps1:218`). A booking can fail to get guests with no
   outward signal.
3. **Rule changes are not retroactive.** When the white-glove match was widened from
   `dr-migrate-white-glove-kickoff` to `white-glove` (commit `d68ceab`), existing
   bookings were not revisited. The 25 Sep White Glove Working Session for
   Ecclesiastical Insurance is still missing Luke Lloyd and Joey Undis.

A booking that is missing its guests is not detectable today without manually opening
it. This design adds a scheduled reconciler that detects and closes those gaps.

## Goals

- Detect any upcoming booking whose guests do not match the rules.
- Close the gap automatically when it is safe to do so.
- Surface the gap to a human when it is not.
- Eliminate the duplicated guest-rule logic that would otherwise exist in two places.

## Non-goals

- Removing guests who should not be there. The reconciler only adds. Removal is
  destructive, harder to reason about, and there is no current need.
- Reconciling past or cancelled bookings.
- Replacing the webhook. The webhook stays the fast path; the reconciler is the
  backstop.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Write or report | Auto-add when booking starts >24h from now; report-only inside 24h | Adding a guest makes Cal.com email a calendar update to every attendee, the customer included. Beyond 24h that is unremarkable. Inside 24h it is disruptive enough to want a human deciding. |
| Rule location | Shared PowerShell module, rules as a data table | Two copies of the rules would drift — which is the exact class of bug the reconciler exists to catch. A data table also makes the matcher a pure function, so it is unit-testable. |
| Cadence and window | Hourly, bookings starting within 30 days | Closes a gap within the hour. ~720 runs/month at two API calls each is negligible on consumption. A 30-day window covers the real booking horizon, so a kickoff booked three weeks out is checked immediately rather than entering the window late and tripping the 24h rule. |
| Alert channel | Notion database row plus a comment that @-mentions Adam | The comment is what produces the notification. The row gives a triageable history that a transient alert does not. Follows the established pattern of automations writing to ⚙️ Operations. |
| Notion delivery | Function calls the Notion REST API directly | The reconciler is the reliability backstop; routing its alerts through a second scheduler would make a missed alert depend on two systems working. Cost is a Notion token in app settings. |

## Architecture

### Components

| Path | Purpose | Depends on |
|---|---|---|
| `Modules/CalGuestRules.psm1` | Rules data table and `Get-ExpectedGuests`. Pure logic, no I/O. | nothing |
| `Modules/NotionAlert.psm1` | `Write-NotionAlert` — upserts a row, optionally comments. | Notion REST API |
| `Modules/CalApi.psm1` | Thin wrappers: `Get-CalBookings`, `Add-CalBookingGuests`. | Cal REST API |
| `cal-automation/run.ps1` | Existing webhook, refactored to import `CalGuestRules`. | modules |
| `cal-reconcile/` | New timer-triggered function. | all modules |
| `tests/` | Pester specs for the pure functions. | nothing |

`profile.ps1` adds `Modules/` to `$env:PSModulePath` at cold start so both functions
resolve the imports.

### Rules table

```powershell
$GuestRules = @(
    @{
        name   = 'always'
        match  = { $true }
        guests = @(
            @{ email = 'Sandra.Murray@altra.cloud'; name = 'Sandra Murray' }
        )
    },
    @{
        name   = 'white-glove'
        match  = { param($b) $b.slug -like '*white-glove*' }
        guests = @(
            @{ email = 'luke.lloyd@altra.cloud'; name = 'Luke Lloyd' },
            @{ email = 'Joey.Undis@altra.cloud'; name = 'Joey Undis' }
        )
    }
)
```

`Get-ExpectedGuests` takes a normalised booking and returns the union of `guests`
across every rule whose `match` returns true. Adding a rule means adding a table
entry, not editing logic.

### Normalised booking shape

The webhook payload and the `GET /v2/bookings` response describe the same booking
with different shapes. Both are mapped to one internal shape before the rules see
them, so the matcher has a single input contract:

```
uid, slug, title, startUtc, customerCompany, bookingUrl, actualGuestEmails[]
```

This is the seam that lets one rules module serve both callers.

### Data flow

```
hourly timer (0 0 * * * *)
  │
  ├─ GET /v2/bookings?status=upcoming&afterStart=now&beforeEnd=now+30d
  │
  └─ for each booking:
       expected = Get-ExpectedGuests(normalised)
       actual   = attendees[].email ∪ guests[]        (case-insensitive)
       missing  = expected − actual

       missing is empty          → log ReconcileClean
       startUtc > now + 24h      → POST guests
                                     ok   → log ReconcileFixed, Notion row, no comment
                                     fail → log ReconcileFailed, Notion row + comment
       startUtc <= now + 24h     → log ReconcileGapReported, Notion row + comment
```

Comparing against actual attendees rather than against what the webhook believes it
did has a useful side effect: it settles whether Sandra Murray is being added by the
webhook or was a booking-form default all along. If the first runs report clean, the
webhook is working and she was already there.

## Notion table

`Cal Guest Reconciliation`, created under ⚙️ Operations.

| Property | Type | Notes |
|---|---|---|
| `Booking` | title | Booking title |
| `Status` | select | `Auto-fixed` (green), `Needs action` (red), `Failed` (orange) |
| `Booking UID` | text | Idempotency key |
| `Starts` | date | Booking start, UTC |
| `Missing Guests` | text | Comma-separated emails |
| `Event Type` | text | Event type slug |
| `Customer` | text | From `bookingFieldsResponses.customer_company_name` |
| `Booking URL` | url | Deep link to the booking |
| `Detected` | created time | System-managed |

### Idempotency

The sweep runs hourly. Without a guard, one unresolved gap inside the 24h window
would produce 24 rows and 24 notifications.

Before writing, query the database for a row with the same `Booking UID` and a
`Status` other than `Auto-fixed`. If one exists, update it in place and **do not**
post a second comment. One notification per gap.

### The comment

Posted only for `Needs action` and `Failed`. Body opens with a user mention of
`20e044ce-9d47-4f6a-8b3a-4c7c79b769b7`, which is what triggers the Notion
notification, followed by the booking, its start time, and the missing guests.

## Error handling

| Failure | Behaviour |
|---|---|
| Cal API list fails | Log `ReconcileFailed`, exit. Next hourly run retries. |
| One booking throws | Isolated in try/catch. Sweep continues; other bookings still reconcile. |
| Guest add fails | Log with `httpStatus` and `responseBody`, Notion row as `Failed` plus comment. |
| Notion write fails | Log and continue. The App Insights record still exists, so nothing is lost — Notion is a notification channel, not the system of record. |
| Missing config | Log `MissingConfig` naming the setting, exit non-destructively. |

Logging reuses the existing `Write-StructuredLog` shape — single-line JSON with
`timestampUtc`, `level`, `event`, and a correlation ID — so the reconciler's output
is queryable by the same KQL and visible in the same workbook.

## Configuration

| Setting | Notes |
|---|---|
| `CAL_API_KEY` | Already present |
| `NOTION_TOKEN` | Integration token, reused from the existing calendar sync integration |
| `NOTION_DB_ID` | Created as part of this work |
| `NOTION_MENTION_USER_ID` | `20e044ce-9d47-4f6a-8b3a-4c7c79b769b7` |
| `RECONCILE_WINDOW_DAYS` | Default 30 |
| `RECONCILE_AUTO_ADD_THRESHOLD_HOURS` | Default 24 |

Thresholds are settings rather than constants so the 24h rule can be tuned without a
deploy.

The integration already holds full permissions over the ⚙️ Operations space, and the
database is created as a child of it, so access is inherited and no manual connection
step is needed. This is also why the database must live under Operations rather than
at workspace root: parented elsewhere, the integration would get a 404 on a database
plainly visible in the UI.

## Testing

`Get-ExpectedGuests` and the missing-guest diff are pure functions and carry the
logic worth protecting. Pester specs cover them, built TDD — test first, watch it
fail, then implement:

- A booking with slug `white-glove-session` expects three guests.
- A booking with slug `partner-intro` expects one.
- Email comparison is case-insensitive: `Sandra.Murray@` matches `sandra.murray@`.
- A booking already holding every expected guest yields an empty missing set.
- Both payload shapes — webhook and list response — normalise to the same result.

Fixtures come from the two real bookings already observed, saved as JSON. No test
calls a live API.

The I/O wrappers are deliberately thin enough to verify by inspection; they are not
worth mocking an HTTP stack to cover.

## Rollback

The reconciler is additive — a new folder plus new modules. Rolling back means
deleting the `cal-reconcile` timer or disabling the function in the portal; the
webhook is unaffected.

The one shared edge is `cal-automation/run.ps1` switching to the rules module. If
that refactor misbehaves, reverting that single file restores the hardcoded lists
while leaving the reconciler running.

## Open questions

None blocking. The name of the Notion integration to reuse is still to be confirmed
and affects documentation only, not the code.
