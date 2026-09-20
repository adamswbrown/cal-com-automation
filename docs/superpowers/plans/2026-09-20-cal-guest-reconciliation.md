# Cal.com Guest Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an hourly timer-triggered Azure Function that finds upcoming Cal.com bookings missing their expected guests, adds them when the booking is more than 24 hours away, and raises a Notion row plus an @-mention comment when it is not.

**Architecture:** Guest rules move out of the webhook into a shared PowerShell module holding a rules data table, so the webhook and the new reconciler answer "who should be on this booking?" identically. Both payload shapes — webhook and list-API — normalise to one internal booking object before the rules see them. Thin I/O modules wrap the Cal and Notion REST APIs; all decision logic stays pure and unit-tested.

**Tech Stack:** PowerShell 7.4 (Azure Functions worker), Pester 5 for tests, Azure Functions v4 extension bundle, Cal.com API v2 (`2024-08-13`), Notion API `2022-06-28`.

**Spec:** `docs/superpowers/specs/2026-09-20-cal-guest-reconciliation-design.md`

## Global Constraints

- PowerShell worker runtime is **7.4** (`local.settings.json`). Local dev is 7.6.2; avoid syntax newer than 7.4.
- Cal API base is `https://api.cal.com/v2`, header `cal-api-version: 2024-08-13`.
- Notion API base is `https://api.notion.com/v1`, header `Notion-Version: 2022-06-28`.
- All logging uses the existing single-line-compressed-JSON shape with `timestampUtc`, `level`, `event`, and a correlation id. Never multi-line JSON — App Insights splits it across rows and it becomes unparseable.
- The reconciler **only adds** guests. Never remove.
- Email comparison is always case-insensitive.
- No secrets in the repo. Every credential is an app setting read from `$env:`.
- Notion database must be parented under ⚙️ Operations (`350ef850-f293-81e1-afb8-d9478f631977`) so the integration inherits access.
- Adam's Notion user id for mentions: `20e044ce-9d47-4f6a-8b3a-4c7c79b769b7`.

---

### Task 0: Test harness and module path

**Files:**
- Create: `tests/Fixtures/booking-white-glove.json`
- Create: `tests/Fixtures/booking-partner-intro.json`
- Create: `tests/Fixtures/webhook-white-glove.json`
- Modify: `profile.ps1`
- Modify: `.funcignore`

**Interfaces:**
- Consumes: nothing
- Produces: `$env:PSModulePath` includes `<app root>/Modules` at cold start; fixture files that every later test loads.

- [ ] **Step 1: Install Pester 5**

```bash
pwsh -NoProfile -c "Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

- [ ] **Step 2: Verify it installed**

Run: `pwsh -NoProfile -c "(Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version"`
Expected: `5.5.0` or higher.

- [ ] **Step 3: Create the white-glove list-API fixture**

Create `tests/Fixtures/booking-white-glove.json`. This is a real booking, trimmed to the fields the code reads:

```json
{
  "uid": "8QUGCCgAWACpqQBmksPwUw",
  "title": "White Glove Working Session between Adam Brown and Errol McKenzie",
  "start": "2026-09-25T14:00:00.000Z",
  "end": "2026-09-25T15:00:00.000Z",
  "status": "accepted",
  "eventType": { "id": 6153763, "slug": "white-glove-session" },
  "attendees": [
    { "name": "Sandra Murray", "email": "Sandra.Murray@altra.cloud" },
    { "name": "Errol McKenzie", "email": "errolmc@softcat.com" }
  ],
  "guests": ["Sandra.Murray@altra.cloud"],
  "bookingFieldsResponses": {
    "customer_company_name": "Ecclesiastical Insurance",
    "partner_name": "Softcat"
  }
}
```

- [ ] **Step 4: Create the partner-intro fixture**

Create `tests/Fixtures/booking-partner-intro.json`:

```json
{
  "uid": "kuHZrB8c9z3x17GX45ycvc",
  "title": "Partner / Seller Intro Call between Adam Brown and Lance Waidzunas",
  "start": "2026-09-23T15:30:00.000Z",
  "end": "2026-09-23T16:00:00.000Z",
  "status": "accepted",
  "eventType": { "id": 6153675, "slug": "partner-intro" },
  "attendees": [
    { "name": "Lance Waidzunas", "email": "lance.waidzunas@trustedtechteam.com" },
    { "name": "Sandra Murray", "email": "Sandra.Murray@altra.cloud" }
  ],
  "guests": ["Sandra.Murray@altra.cloud"],
  "bookingFieldsResponses": {
    "customer_company_name": "TrustedTech"
  }
}
```

- [ ] **Step 5: Create the webhook-shape fixture**

Create `tests/Fixtures/webhook-white-glove.json`. Note the different shape — this is what proves normalisation works:

```json
{
  "triggerEvent": "BOOKING_CREATED",
  "payload": {
    "uid": "8QUGCCgAWACpqQBmksPwUw",
    "title": "White Glove Working Session between Adam Brown and Errol McKenzie",
    "startTime": "2026-09-25T14:00:00.000Z",
    "eventType": { "slug": "white-glove-session", "title": "White Glove Working Session" },
    "attendees": [
      { "name": "Errol McKenzie", "email": "errolmc@softcat.com" }
    ],
    "bookingFieldsResponses": {
      "customer_company_name": "Ecclesiastical Insurance"
    }
  }
}
```

- [ ] **Step 6: Add the Modules directory to the module path**

In `profile.ps1`, append at the end of the file:

```powershell
# Make shared modules importable by name from every function in this app.
$modulesPath = Join-Path $PSScriptRoot 'Modules'
if (Test-Path $modulesPath) {
    if ($env:PSModulePath -notlike "*$modulesPath*") {
        $env:PSModulePath = "$modulesPath$([System.IO.Path]::PathSeparator)$env:PSModulePath"
    }
}
```

- [ ] **Step 7: Keep tests out of the deployment package**

Confirm `.funcignore` contains a `test` line. It already does — add `tests` and `docs` beneath it so both are excluded:

```
tests
docs
```

- [ ] **Step 8: Commit**

```bash
git add tests/ profile.ps1 .funcignore
git commit -m "Add test fixtures and shared module path"
```

---

### Task 1: CalGuestRules module

The heart of the change. Pure functions, no I/O, fully tested.

**Files:**
- Create: `Modules/CalGuestRules/CalGuestRules.psm1`
- Create: `Modules/CalGuestRules/CalGuestRules.psd1`
- Test: `tests/CalGuestRules.Tests.ps1`

**Interfaces:**
- Consumes: fixtures from Task 0.
- Produces:
  - `ConvertFrom-CalBooking -Booking <object>` → normalised booking
  - `ConvertFrom-CalWebhookPayload -Payload <object>` → normalised booking
  - `Get-ExpectedGuests -Booking <normalised>` → `@(@{email;name})`
  - `Get-MissingGuests -Booking <normalised>` → `@(@{email;name})`
  - Normalised shape: `Uid`, `Slug`, `Title`, `StartUtc` (`[datetime]`), `CustomerCompany`, `ActualGuestEmails` (`string[]`, lowercased)

- [ ] **Step 1: Write the failing tests**

Create `tests/CalGuestRules.Tests.ps1`:

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'Modules' 'CalGuestRules' 'CalGuestRules.psm1'
    Import-Module $script:ModulePath -Force

    $script:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'
    $script:WhiteGlove = Get-Content (Join-Path $script:FixtureDir 'booking-white-glove.json') -Raw | ConvertFrom-Json
    $script:PartnerIntro = Get-Content (Join-Path $script:FixtureDir 'booking-partner-intro.json') -Raw | ConvertFrom-Json
    $script:Webhook = Get-Content (Join-Path $script:FixtureDir 'webhook-white-glove.json') -Raw | ConvertFrom-Json
}

Describe 'ConvertFrom-CalBooking' {
    It 'extracts the fields the rules need' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $b.Uid | Should -Be '8QUGCCgAWACpqQBmksPwUw'
        $b.Slug | Should -Be 'white-glove-session'
        $b.CustomerCompany | Should -Be 'Ecclesiastical Insurance'
        $b.StartUtc | Should -BeOfType [datetime]
    }

    It 'lowercases actual guest emails and includes attendees' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $b.ActualGuestEmails | Should -Contain 'sandra.murray@altra.cloud'
        $b.ActualGuestEmails | Should -Contain 'errolmc@softcat.com'
    }

    It 'does not duplicate an email present in both attendees and guests' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        ($b.ActualGuestEmails | Where-Object { $_ -eq 'sandra.murray@altra.cloud' }).Count | Should -Be 1
    }
}

Describe 'ConvertFrom-CalWebhookPayload' {
    It 'normalises the webhook shape to the same contract' {
        $b = ConvertFrom-CalWebhookPayload -Payload $script:Webhook.payload
        $b.Uid | Should -Be '8QUGCCgAWACpqQBmksPwUw'
        $b.Slug | Should -Be 'white-glove-session'
        $b.CustomerCompany | Should -Be 'Ecclesiastical Insurance'
    }

    It 'produces the same expected guests as the list-API shape' {
        $fromWebhook = Get-ExpectedGuests -Booking (ConvertFrom-CalWebhookPayload -Payload $script:Webhook.payload)
        $fromList = Get-ExpectedGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        ($fromWebhook.email | Sort-Object) | Should -Be ($fromList.email | Sort-Object)
    }
}

Describe 'Get-ExpectedGuests' {
    It 'returns three guests for a white-glove booking' {
        $g = Get-ExpectedGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        $g.Count | Should -Be 3
        $g.email | Should -Contain 'Sandra.Murray@altra.cloud'
        $g.email | Should -Contain 'luke.lloyd@altra.cloud'
        $g.email | Should -Contain 'Joey.Undis@altra.cloud'
    }

    It 'returns only the always-guest for a non-white-glove booking' {
        $g = Get-ExpectedGuests -Booking (ConvertFrom-CalBooking -Booking $script:PartnerIntro)
        $g.Count | Should -Be 1
        $g.email | Should -Be 'Sandra.Murray@altra.cloud'
    }
}

Describe 'Get-MissingGuests' {
    It 'reports the two white-glove guests as missing' {
        $m = Get-MissingGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        $m.Count | Should -Be 2
        $m.email | Should -Contain 'luke.lloyd@altra.cloud'
        $m.email | Should -Contain 'Joey.Undis@altra.cloud'
    }

    It 'matches case-insensitively so Sandra is not reported missing' {
        $m = Get-MissingGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        $m.email | Should -Not -Contain 'Sandra.Murray@altra.cloud'
    }

    It 'returns nothing when every expected guest is present' {
        $m = Get-MissingGuests -Booking (ConvertFrom-CalBooking -Booking $script:PartnerIntro)
        @($m).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/CalGuestRules.Tests.ps1 -Output Detailed"`
Expected: FAIL — module file not found at the import path.

- [ ] **Step 3: Write the module manifest**

Create `Modules/CalGuestRules/CalGuestRules.psd1`:

```powershell
@{
    RootModule        = 'CalGuestRules.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d'
    Author            = 'Altra'
    Description       = 'Guest rules and booking normalisation shared by the Cal.com webhook and reconciler.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'ConvertFrom-CalBooking',
        'ConvertFrom-CalWebhookPayload',
        'Get-ExpectedGuests',
        'Get-MissingGuests'
    )
}
```

- [ ] **Step 4: Write the module**

Create `Modules/CalGuestRules/CalGuestRules.psm1`:

```powershell
# Guest rules for Cal.com bookings.
#
# Rules are data, not logic: each entry pairs a match predicate with the guests
# that rule contributes. A booking's expected guests are the union across every
# rule whose predicate returns true. Add a rule by adding a table entry.
$script:GuestRules = @(
    @{
        name   = 'always'
        match  = { param($Booking) $true }
        guests = @(
            @{ email = 'Sandra.Murray@altra.cloud'; name = 'Sandra Murray' }
        )
    },
    @{
        name   = 'white-glove'
        match  = { param($Booking) $Booking.Slug -like '*white-glove*' }
        guests = @(
            @{ email = 'luke.lloyd@altra.cloud'; name = 'Luke Lloyd' },
            @{ email = 'Joey.Undis@altra.cloud'; name = 'Joey Undis' }
        )
    }
)

function New-NormalisedBooking {
    param(
        [string]$Uid,
        [string]$Slug,
        [string]$Title,
        [string]$StartUtcRaw,
        [string]$CustomerCompany,
        [string[]]$ActualGuestEmails
    )

    $start = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($StartUtcRaw)) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse(
                $StartUtcRaw,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$parsed)) {
            $start = $parsed
        }
    }

    $emails = @($ActualGuestEmails |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Select-Object -Unique)

    [pscustomobject]@{
        Uid               = $Uid
        Slug              = $Slug
        Title             = $Title
        StartUtc          = $start
        CustomerCompany   = $CustomerCompany
        ActualGuestEmails = $emails
    }
}

function ConvertFrom-CalBooking {
    <#
        .SYNOPSIS
        Normalises a booking from GET /v2/bookings into the shape the rules consume.
    #>
    param([Parameter(Mandatory)]$Booking)

    $emails = @()
    $emails += @($Booking.attendees | ForEach-Object { [string]$_.email })
    $emails += @($Booking.guests | ForEach-Object { [string]$_ })

    New-NormalisedBooking `
        -Uid ([string]$Booking.uid) `
        -Slug ([string]$Booking.eventType.slug) `
        -Title ([string]$Booking.title) `
        -StartUtcRaw ([string]$Booking.start) `
        -CustomerCompany ([string]$Booking.bookingFieldsResponses.customer_company_name) `
        -ActualGuestEmails $emails
}

function ConvertFrom-CalWebhookPayload {
    <#
        .SYNOPSIS
        Normalises a webhook payload into the same shape as ConvertFrom-CalBooking.

        .DESCRIPTION
        The webhook and the list API describe the same booking with different field
        names (startTime vs start, no top-level guests array). Both funnel through
        here so the rules have a single input contract.
    #>
    param([Parameter(Mandatory)]$Payload)

    $emails = @()
    $emails += @($Payload.attendees | ForEach-Object { [string]$_.email })
    $emails += @($Payload.guests | ForEach-Object { [string]$_ })

    $slug = [string]$Payload.eventType.slug
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = [string]$Payload.eventType.title
    }

    New-NormalisedBooking `
        -Uid ([string]$Payload.uid) `
        -Slug $slug `
        -Title ([string]$Payload.title) `
        -StartUtcRaw ([string]$Payload.startTime) `
        -CustomerCompany ([string]$Payload.bookingFieldsResponses.customer_company_name) `
        -ActualGuestEmails $emails
}

function Get-ExpectedGuests {
    <#
        .SYNOPSIS
        Returns every guest the rules say belongs on this booking.
    #>
    param([Parameter(Mandatory)]$Booking)

    $expected = [ordered]@{}

    foreach ($rule in $script:GuestRules) {
        if (& $rule.match $Booking) {
            foreach ($guest in $rule.guests) {
                $key = $guest.email.ToLowerInvariant()
                if (-not $expected.Contains($key)) {
                    $expected[$key] = $guest
                }
            }
        }
    }

    @($expected.Values)
}

function Get-MissingGuests {
    <#
        .SYNOPSIS
        Returns expected guests not already on the booking. Comparison is
        case-insensitive: Cal.com echoes back whatever casing was submitted.
    #>
    param([Parameter(Mandatory)]$Booking)

    @(Get-ExpectedGuests -Booking $Booking |
        Where-Object { $Booking.ActualGuestEmails -notcontains $_.email.ToLowerInvariant() })
}

Export-ModuleMember -Function ConvertFrom-CalBooking, ConvertFrom-CalWebhookPayload, Get-ExpectedGuests, Get-MissingGuests
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/CalGuestRules.Tests.ps1 -Output Detailed"`
Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add Modules/CalGuestRules tests/CalGuestRules.Tests.ps1
git commit -m "Add shared CalGuestRules module with rules as a data table"
```

---

### Task 2: Refactor the webhook onto the shared module

**Files:**
- Modify: `cal-automation/run.ps1:57-140`

**Interfaces:**
- Consumes: `ConvertFrom-CalWebhookPayload`, `Get-ExpectedGuests` from Task 1.
- Produces: no new interface. Behaviour must be unchanged.

- [ ] **Step 1: Import the module and delete the hardcoded lists**

In `cal-automation/run.ps1`, replace the block from `$DefaultGuestsToAdd = @(` through the closing `)` of `$WhiteGloveGuestsToAdd`, and the `$WhiteGloveSlug` line, with:

```powershell
Import-Module CalGuestRules -ErrorAction Stop
```

Keep `$CalApiBase` where it is.

- [ ] **Step 2: Replace the guest-selection block**

Replace lines from `# Add extra people for white glove kickoff bookings.` through the end of the `GuestSelection` log call with:

```powershell
# Guest selection is owned by the CalGuestRules module so the webhook and the
# reconciler cannot drift apart.
$normalisedBooking = ConvertFrom-CalWebhookPayload -Payload $body.payload
$GuestsToAdd = @(Get-ExpectedGuests -Booking $normalisedBooking)

Write-StructuredLog -Level "Information" -Event "GuestSelection" -Data @{
    bookingUid = $bookingUid
    slug       = $normalisedBooking.Slug
    guestCount = $GuestsToAdd.Count
    guests     = @($GuestsToAdd | ForEach-Object { [string]$_.email })
}
```

- [ ] **Step 3: Verify the script still parses**

Run: `pwsh -NoProfile -c "\$null = [System.Management.Automation.Language.Parser]::ParseFile('cal-automation/run.ps1', [ref]\$null, [ref]\$null); 'parsed ok'"`
Expected: `parsed ok`

- [ ] **Step 4: Verify guest selection is unchanged for both fixtures**

Run:

```bash
pwsh -NoProfile -c "
Import-Module ./Modules/CalGuestRules/CalGuestRules.psm1 -Force
\$w = Get-Content tests/Fixtures/webhook-white-glove.json -Raw | ConvertFrom-Json
(Get-ExpectedGuests -Booking (ConvertFrom-CalWebhookPayload -Payload \$w.payload)).email -join ','
"
```

Expected: `Sandra.Murray@altra.cloud,luke.lloyd@altra.cloud,Joey.Undis@altra.cloud`

- [ ] **Step 5: Commit**

```bash
git add cal-automation/run.ps1
git commit -m "Move webhook guest selection onto the shared rules module"
```

---

### Task 3: Cal API wrapper module

**Files:**
- Create: `Modules/CalApi/CalApi.psm1`
- Create: `Modules/CalApi/CalApi.psd1`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Get-CalUpcomingBookings -ApiKey <string> -WindowDays <int>` → array of raw booking objects
  - `Add-CalBookingGuests -ApiKey <string> -BookingUid <string> -Guests <array>` → `@{ Success = [bool]; HttpStatus = [int?]; ResponseBody = [string] }`

- [ ] **Step 1: Write the manifest**

Create `Modules/CalApi/CalApi.psd1`:

```powershell
@{
    RootModule        = 'CalApi.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c2a3b4d5-6f70-4b81-9c2d-1e2f3a4b5c6d'
    Author            = 'Altra'
    Description       = 'Thin wrappers over the Cal.com v2 REST API.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Get-CalUpcomingBookings', 'Add-CalBookingGuests')
}
```

- [ ] **Step 2: Write the module**

Create `Modules/CalApi/CalApi.psm1`:

```powershell
$script:CalApiBase = 'https://api.cal.com/v2'
$script:CalApiVersion = '2024-08-13'

function Get-CalHeaders {
    param([Parameter(Mandatory)][string]$ApiKey)
    @{
        Authorization     = "Bearer $ApiKey"
        'Content-Type'    = 'application/json'
        'cal-api-version' = $script:CalApiVersion
    }
}

function Get-CalUpcomingBookings {
    <#
        .SYNOPSIS
        Lists upcoming bookings starting within the given window, following pagination.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [int]$WindowDays = 30
    )

    $now = (Get-Date).ToUniversalTime()
    $afterStart = $now.ToString('o')
    $beforeEnd = $now.AddDays($WindowDays).ToString('o')

    $all = @()
    $skip = 0
    $take = 100

    do {
        $uri = "$script:CalApiBase/bookings?status=upcoming&afterStart=$afterStart&beforeEnd=$beforeEnd&take=$take&skip=$skip"
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-CalHeaders -ApiKey $ApiKey)

        $batch = @($response.data)
        $all += $batch

        $skip += $take
        $hasMore = $response.pagination.hasNextPage -eq $true
    } while ($hasMore -and $batch.Count -gt 0)

    $all
}

function Add-CalBookingGuests {
    <#
        .SYNOPSIS
        Adds guests to a booking. Returns a result object rather than throwing so
        callers can record the failure and carry on with the next booking.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$BookingUid,
        [Parameter(Mandatory)][array]$Guests
    )

    $uri = "$script:CalApiBase/bookings/$BookingUid/guests"
    $payload = @{ guests = $Guests } | ConvertTo-Json -Depth 5

    try {
        $null = Invoke-RestMethod -Method Post -Uri $uri -Headers (Get-CalHeaders -ApiKey $ApiKey) -Body $payload
        return @{ Success = $true; HttpStatus = 200; ResponseBody = $null }
    }
    catch {
        $httpStatus = $null
        $responseBody = $null

        if ($_.Exception.Response) {
            try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch { $httpStatus = $null }
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Dispose()
                    $stream.Dispose()
                }
            }
            catch { $responseBody = $null }
        }

        if (-not $responseBody) { $responseBody = [string]$_.Exception.Message }

        return @{ Success = $false; HttpStatus = $httpStatus; ResponseBody = $responseBody }
    }
}

Export-ModuleMember -Function Get-CalUpcomingBookings, Add-CalBookingGuests
```

- [ ] **Step 3: Verify the module imports and exports both functions**

Run:

```bash
pwsh -NoProfile -c "Import-Module ./Modules/CalApi/CalApi.psm1 -Force; (Get-Command -Module CalApi).Name -join ','"
```

Expected: `Add-CalBookingGuests,Get-CalUpcomingBookings`

- [ ] **Step 4: Commit**

```bash
git add Modules/CalApi
git commit -m "Add Cal.com API wrapper module"
```

---

### Task 4: Notion alert module

**Files:**
- Create: `Modules/NotionAlert/NotionAlert.psm1`
- Create: `Modules/NotionAlert/NotionAlert.psd1`

**Interfaces:**
- Consumes: nothing.
- Produces: `Write-NotionAlert -Token -DatabaseId -MentionUserId -Status -Booking -MissingGuests -Detail` → `@{ Success = [bool]; PageId = [string]; Created = [bool]; Commented = [bool]; Error = [string] }`

`-Status` is one of `Auto-fixed`, `Needs action`, `Failed`. A comment is posted only for the latter two, and only when the row was newly created — an existing open row is updated silently so an hourly sweep cannot produce 24 notifications for one gap.

- [ ] **Step 1: Write the manifest**

Create `Modules/NotionAlert/NotionAlert.psd1`:

```powershell
@{
    RootModule        = 'NotionAlert.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd3b4c5e6-7081-4c92-8d3e-2f3a4b5c6d7e'
    Author            = 'Altra'
    Description       = 'Writes reconciliation results to a Notion database and notifies via comment mention.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Write-NotionAlert')
}
```

- [ ] **Step 2: Write the module**

Create `Modules/NotionAlert/NotionAlert.psm1`:

```powershell
$script:NotionApiBase = 'https://api.notion.com/v1'
$script:NotionVersion = '2022-06-28'

function Get-NotionHeaders {
    param([Parameter(Mandatory)][string]$Token)
    @{
        Authorization    = "Bearer $Token"
        'Notion-Version' = $script:NotionVersion
        'Content-Type'   = 'application/json'
    }
}

function Find-NotionOpenRow {
    <#
        .SYNOPSIS
        Finds an existing non-resolved row for this booking, so repeat sweeps
        update in place instead of creating a row per hour.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DatabaseId,
        [Parameter(Mandatory)][string]$BookingUid
    )

    $filter = @{
        filter = @{
            and = @(
                @{ property = 'Booking UID'; rich_text = @{ equals = $BookingUid } },
                @{ property = 'Status'; select = @{ does_not_equal = 'Auto-fixed' } }
            )
        }
        page_size = 1
    } | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Method Post `
        -Uri "$script:NotionApiBase/databases/$DatabaseId/query" `
        -Headers (Get-NotionHeaders -Token $Token) `
        -Body $filter

    if ($response.results -and $response.results.Count -gt 0) {
        return $response.results[0].id
    }
    return $null
}

function Write-NotionAlert {
    <#
        .SYNOPSIS
        Records a reconciliation result as a Notion row, commenting to notify when
        a human needs to act.

        .DESCRIPTION
        Never throws. Notion is a notification channel, not the system of record —
        a Notion outage must not fail the sweep, because App Insights already holds
        the authoritative log line.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DatabaseId,
        [string]$MentionUserId,
        [Parameter(Mandatory)][ValidateSet('Auto-fixed', 'Needs action', 'Failed')][string]$Status,
        [Parameter(Mandatory)]$Booking,
        [array]$MissingGuests = @(),
        [string]$Detail = ''
    )

    try {
        $missingText = ($MissingGuests | ForEach-Object { [string]$_.email }) -join ', '
        $headers = Get-NotionHeaders -Token $Token

        $existingPageId = Find-NotionOpenRow -Token $Token -DatabaseId $DatabaseId -BookingUid $Booking.Uid

        $properties = @{
            'Booking'        = @{ title = @(@{ text = @{ content = [string]$Booking.Title } }) }
            'Status'         = @{ select = @{ name = $Status } }
            'Booking UID'    = @{ rich_text = @(@{ text = @{ content = [string]$Booking.Uid } }) }
            'Starts'         = @{ date = @{ start = $Booking.StartUtc.ToString('o') } }
            'Missing Guests' = @{ rich_text = @(@{ text = @{ content = $missingText } }) }
            'Event Type'     = @{ rich_text = @(@{ text = @{ content = [string]$Booking.Slug } }) }
            'Customer'       = @{ rich_text = @(@{ text = @{ content = [string]$Booking.CustomerCompany } }) }
            'Booking URL'    = @{ url = "https://app.cal.com/booking/$($Booking.Uid)" }
        }

        $created = $false

        if ($existingPageId) {
            $body = @{ properties = $properties } | ConvertTo-Json -Depth 10
            $null = Invoke-RestMethod -Method Patch -Uri "$script:NotionApiBase/pages/$existingPageId" -Headers $headers -Body $body
            $pageId = $existingPageId
        }
        else {
            $body = @{
                parent     = @{ database_id = $DatabaseId }
                properties = $properties
            } | ConvertTo-Json -Depth 10
            $page = Invoke-RestMethod -Method Post -Uri "$script:NotionApiBase/pages" -Headers $headers -Body $body
            $pageId = $page.id
            $created = $true
        }

        # Comment only on a newly created row that needs a human. Updating an
        # existing open row must stay silent or an hourly sweep becomes a siren.
        $commented = $false
        if ($created -and $Status -ne 'Auto-fixed' -and $MentionUserId) {
            $summary = if ($Status -eq 'Failed') {
                "Could not add guests to this booking. $Detail"
            }
            else {
                "Starts within 24h, so guests were not auto-added. Missing: $missingText"
            }

            $commentBody = @{
                parent    = @{ page_id = $pageId }
                rich_text = @(
                    @{ type = 'mention'; mention = @{ type = 'user'; user = @{ id = $MentionUserId } } },
                    @{ type = 'text'; text = @{ content = " $summary" } }
                )
            } | ConvertTo-Json -Depth 10

            $null = Invoke-RestMethod -Method Post -Uri "$script:NotionApiBase/comments" -Headers $headers -Body $commentBody
            $commented = $true
        }

        return @{ Success = $true; PageId = $pageId; Created = $created; Commented = $commented; Error = $null }
    }
    catch {
        return @{ Success = $false; PageId = $null; Created = $false; Commented = $false; Error = [string]$_.Exception.Message }
    }
}

Export-ModuleMember -Function Write-NotionAlert
```

- [ ] **Step 3: Verify the module imports**

Run:

```bash
pwsh -NoProfile -c "Import-Module ./Modules/NotionAlert/NotionAlert.psm1 -Force; (Get-Command -Module NotionAlert).Name"
```

Expected: `Write-NotionAlert`

- [ ] **Step 4: Commit**

```bash
git add Modules/NotionAlert
git commit -m "Add Notion alert module with comment notification"
```

---

### Task 5: The reconciler function

**Files:**
- Create: `cal-reconcile/function.json`
- Create: `cal-reconcile/run.ps1`

**Interfaces:**
- Consumes: every module from Tasks 1, 3, 4.
- Produces: the deployable timer function. No downstream consumer.

- [ ] **Step 1: Write the timer binding**

Create `cal-reconcile/function.json`:

```json
{
  "bindings": [
    {
      "name": "Timer",
      "type": "timerTrigger",
      "direction": "in",
      "schedule": "0 0 * * * *"
    }
  ]
}
```

- [ ] **Step 2: Write the reconciler**

Create `cal-reconcile/run.ps1`:

```powershell
param($Timer)

Import-Module CalGuestRules -ErrorAction Stop
Import-Module CalApi -ErrorAction Stop
Import-Module NotionAlert -ErrorAction Stop

$script:runId = [guid]::NewGuid().ToString()

function Write-StructuredLog {
    param(
        [string]$Level,
        [string]$Event,
        [hashtable]$Data = @{}
    )

    $logEntry = @{
        timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        level        = $Level
        event        = $Event
        invocationId = $script:runId
    }

    foreach ($key in $Data.Keys) { $logEntry[$key] = $Data[$key] }

    $logLine = $logEntry | ConvertTo-Json -Depth 8 -Compress

    switch ($Level) {
        "Error"   { Write-Error $logLine }
        "Warning" { Write-Warning $logLine }
        default   { Write-Host $logLine }
    }
}

# -----------------------------
# Config
# -----------------------------
$apiKey = $env:CAL_API_KEY
$notionToken = $env:NOTION_TOKEN
$notionDbId = $env:NOTION_DB_ID
$mentionUserId = $env:NOTION_MENTION_USER_ID

$windowDays = if ($env:RECONCILE_WINDOW_DAYS) { [int]$env:RECONCILE_WINDOW_DAYS } else { 30 }
$thresholdHours = if ($env:RECONCILE_AUTO_ADD_THRESHOLD_HOURS) { [int]$env:RECONCILE_AUTO_ADD_THRESHOLD_HOURS } else { 24 }

$missingSettings = @()
if (-not $apiKey) { $missingSettings += 'CAL_API_KEY' }
if (-not $notionToken) { $missingSettings += 'NOTION_TOKEN' }
if (-not $notionDbId) { $missingSettings += 'NOTION_DB_ID' }

if ($missingSettings.Count -gt 0) {
    Write-StructuredLog -Level "Error" -Event "MissingConfig" -Data @{
        missingSettings = $missingSettings
    }
    return
}

Write-StructuredLog -Level "Information" -Event "ReconcileStarted" -Data @{
    windowDays     = $windowDays
    thresholdHours = $thresholdHours
}

# -----------------------------
# Fetch
# -----------------------------
try {
    $bookings = @(Get-CalUpcomingBookings -ApiKey $apiKey -WindowDays $windowDays)
}
catch {
    Write-StructuredLog -Level "Error" -Event "ReconcileFailed" -Data @{
        stage        = "list"
        errorMessage = [string]$_.Exception.Message
    }
    return
}

Write-StructuredLog -Level "Information" -Event "BookingsFetched" -Data @{
    bookingCount = $bookings.Count
}

# -----------------------------
# Reconcile
# -----------------------------
$now = (Get-Date).ToUniversalTime()
$stats = @{ clean = 0; fixed = 0; reported = 0; failed = 0 }

foreach ($raw in $bookings) {
    try {
        $booking = ConvertFrom-CalBooking -Booking $raw
        $missing = @(Get-MissingGuests -Booking $booking)

        if ($missing.Count -eq 0) {
            $stats.clean++
            Write-StructuredLog -Level "Information" -Event "ReconcileClean" -Data @{
                bookingUid = $booking.Uid
                slug       = $booking.Slug
            }
            continue
        }

        $hoursUntilStart = ($booking.StartUtc - $now).TotalHours
        $missingEmails = @($missing | ForEach-Object { [string]$_.email })

        if ($hoursUntilStart -gt $thresholdHours) {
            $result = Add-CalBookingGuests -ApiKey $apiKey -BookingUid $booking.Uid -Guests $missing

            if ($result.Success) {
                $stats.fixed++
                Write-StructuredLog -Level "Information" -Event "ReconcileFixed" -Data @{
                    bookingUid      = $booking.Uid
                    slug            = $booking.Slug
                    addedGuests     = $missingEmails
                    hoursUntilStart = [math]::Round($hoursUntilStart, 1)
                }
                $null = Write-NotionAlert -Token $notionToken -DatabaseId $notionDbId `
                    -MentionUserId $mentionUserId -Status 'Auto-fixed' `
                    -Booking $booking -MissingGuests $missing
            }
            else {
                $stats.failed++
                Write-StructuredLog -Level "Error" -Event "ReconcileFailed" -Data @{
                    stage         = "addGuests"
                    bookingUid    = $booking.Uid
                    missingGuests = $missingEmails
                    httpStatus    = $result.HttpStatus
                    responseBody  = $result.ResponseBody
                }
                $null = Write-NotionAlert -Token $notionToken -DatabaseId $notionDbId `
                    -MentionUserId $mentionUserId -Status 'Failed' `
                    -Booking $booking -MissingGuests $missing `
                    -Detail "HTTP $($result.HttpStatus): $($result.ResponseBody)"
            }
        }
        else {
            $stats.reported++
            Write-StructuredLog -Level "Warning" -Event "ReconcileGapReported" -Data @{
                bookingUid      = $booking.Uid
                slug            = $booking.Slug
                missingGuests   = $missingEmails
                hoursUntilStart = [math]::Round($hoursUntilStart, 1)
                reason          = "within auto-add threshold"
            }
            $null = Write-NotionAlert -Token $notionToken -DatabaseId $notionDbId `
                -MentionUserId $mentionUserId -Status 'Needs action' `
                -Booking $booking -MissingGuests $missing
        }
    }
    catch {
        # One malformed booking must not abort the sweep.
        $stats.failed++
        Write-StructuredLog -Level "Error" -Event "ReconcileBookingError" -Data @{
            bookingUid   = [string]$raw.uid
            errorMessage = [string]$_.Exception.Message
        }
    }
}

Write-StructuredLog -Level "Information" -Event "ReconcileCompleted" -Data @{
    bookingCount = $bookings.Count
    clean        = $stats.clean
    fixed        = $stats.fixed
    reported     = $stats.reported
    failed       = $stats.failed
}
```

- [ ] **Step 3: Verify the script parses**

Run: `pwsh -NoProfile -c "\$null = [System.Management.Automation.Language.Parser]::ParseFile('cal-reconcile/run.ps1', [ref]\$null, [ref]\$null); 'parsed ok'"`
Expected: `parsed ok`

- [ ] **Step 4: Run the full test suite**

Run: `pwsh -NoProfile -c "Invoke-Pester tests/ -Output Detailed"`
Expected: PASS, all tests green.

- [ ] **Step 5: Commit**

```bash
git add cal-reconcile/
git commit -m "Add hourly guest reconciliation timer function"
```

---

### Task 6: Workbook panel and documentation

**Files:**
- Modify: `infra/azure/cal-automation-logs-workbook.bicep`
- Modify: `README.md`

**Interfaces:**
- Consumes: the event names emitted in Task 5.
- Produces: nothing code depends on.

- [ ] **Step 1: Add a reconciler panel to the workbook**

In `infra/azure/cal-automation-logs-workbook.bicep`, add a query item to the workbook's `items` array:

```kusto
traces
| where timestamp > ago(7d)
| where message has "Reconcile"
| extend parsed = parse_json(message)
| project timestamp, event = tostring(parsed.event), bookingUid = tostring(parsed.bookingUid), missing = tostring(parsed.missingGuests), hoursUntilStart = todouble(parsed.hoursUntilStart)
| order by timestamp desc
```

- [ ] **Step 2: Document the reconciler in the README**

Append to `README.md`:

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
git add infra/ README.md
git commit -m "Document reconciler and add workbook panel"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| `Modules/CalGuestRules.psm1` | 1 |
| `Modules/NotionAlert.psm1` | 4 |
| `Modules/CalApi.psm1` | 3 |
| Webhook refactor | 2 |
| `cal-reconcile/` timer | 5 |
| `tests/` Pester specs | 0, 1 |
| `profile.ps1` module path | 0 |
| Normalised booking shape | 1 |
| Data flow incl. 24h threshold | 5 |
| Notion table schema | 4 (written), created manually before deploy |
| Idempotency guard | 4 |
| Comment with mention | 4 |
| Error handling table | 3, 4, 5 |
| Configuration settings | 5, 6 |
| Testing | 0, 1 |
| Rollback | 6 (README) |

No gaps. One deviation worth naming: the Notion database itself is created via the MCP connection before Task 4 runs, not by code — it is a one-time setup step, and a bicep resource cannot create Notion objects.

**Placeholder scan:** none found. Every code step contains runnable content.

**Type consistency:** `ConvertFrom-CalBooking` and `ConvertFrom-CalWebhookPayload` both return the `New-NormalisedBooking` shape; Task 5 uses `.Uid`, `.Slug`, `.Title`, `.StartUtc`, `.CustomerCompany`, all defined in Task 1. `Add-CalBookingGuests` returns `Success`/`HttpStatus`/`ResponseBody`, consumed under those exact names in Task 5. `Write-NotionAlert`'s `-Status` ValidateSet matches the three values Task 5 passes.
