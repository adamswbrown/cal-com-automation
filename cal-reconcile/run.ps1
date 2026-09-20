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
        "Error" { Write-Error $logLine }
        "Warning" { Write-Warning $logLine }
        default { Write-Host $logLine }
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
