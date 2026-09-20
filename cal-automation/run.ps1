param($Request, $TriggerMetadata)

# -----------------------------
# Logging helpers
# -----------------------------
$invocationIdCandidates = @(
    [string]$TriggerMetadata.InvocationId,
    [string]$TriggerMetadata.sys.InvocationId,
    [string]$TriggerMetadata.sys.RandGuid,
    [string]$Request.Headers.'x-functions-request-id',
    [string]$Request.Headers.'x-ms-request-id'
)
$invocationId = $invocationIdCandidates |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($invocationId)) {
    $invocationId = [guid]::NewGuid().ToString()
}

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
        invocationId = $script:invocationId
    }

    foreach ($key in $Data.Keys) {
        $logEntry[$key] = $Data[$key]
    }

    $logLine = $logEntry | ConvertTo-Json -Depth 8 -Compress

    switch ($Level) {
        "Error" { Write-Error $logLine }
        "Warning" { Write-Warning $logLine }
        default { Write-Host $logLine }
    }
}

Write-StructuredLog -Level "Information" -Event "WebhookReceived" -Data @{
    method = [string]$Request.Method
    hasBody = $null -ne $Request.Body
}

# -----------------------------
# Config
# -----------------------------
$CalApiBase = "https://api.cal.com/v2"

Import-Module CalGuestRules -ErrorAction Stop
Import-Module NotionRules -ErrorAction Stop
Import-Module NotionAlert -ErrorAction Stop

$ApiKey = $env:CAL_API_KEY
if (-not $ApiKey) {
    Write-StructuredLog -Level "Error" -Event "MissingConfig" -Data @{
        missingSetting = "CAL_API_KEY"
    }

    return @{
        status = 500
        body   = "CAL_API_KEY not configured"
    }
}

# -----------------------------
# Parse webhook payload
# -----------------------------
$body = $Request.Body
$bookingUid = [string]$body.payload.uid
$eventTypeSlug = [string]$body.payload.eventType.slug
$eventTypeName = [string]$body.payload.eventType.name
$triggerEvent = [string]$body.triggerEvent

if (-not $bookingUid) {
    Write-StructuredLog -Level "Warning" -Event "InvalidPayload" -Data @{
        reason = "booking UID missing"
        triggerEvent = $triggerEvent
    }

    return @{
        status = 400
        body   = "Invalid webhook payload"
    }
}

Write-StructuredLog -Level "Information" -Event "ProcessingBooking" -Data @{
    bookingUid = $bookingUid
    triggerEvent = $triggerEvent
    eventTypeSlug = $eventTypeSlug
    eventTypeName = $eventTypeName
}

# Guest selection is owned by the CalGuestRules module so the webhook and the
# reconciler cannot drift apart. Rules come from Notion, falling back to the
# built-in set if it is unreachable -- a rules failure must not stop a booking
# getting its guests.
$normalisedBooking = ConvertFrom-CalWebhookPayload -Payload $body.payload

$rulesResult = Get-NotionGuestRules -Token $env:NOTION_TOKEN -DatabaseId $env:NOTION_RULES_DB_ID

if ($rulesResult.Fallback) {
    Write-StructuredLog -Level "Error" -Event "RulesFellBack" -Data @{
        bookingUid = $bookingUid
        reason     = $rulesResult.Error
        source     = $rulesResult.Source
    }
}
else {
    Write-StructuredLog -Level "Information" -Event "RulesLoaded" -Data @{
        source    = $rulesResult.Source
        ruleCount = @($rulesResult.Rules).Count
    }
}

$GuestsToAdd = @(Get-ExpectedGuests -Booking $normalisedBooking -Rules $rulesResult.Rules)

Write-StructuredLog -Level "Information" -Event "GuestSelection" -Data @{
    bookingUid = $bookingUid
    slug       = $normalisedBooking.Slug
    guestCount = $GuestsToAdd.Count
    guests     = @($GuestsToAdd | ForEach-Object { [string]$_.email })
}

# -----------------------------
# Headers
# -----------------------------
$headers = @{
    Authorization     = "Bearer $ApiKey"
    "Content-Type"   = "application/json"
    "cal-api-version"= "2024-08-13"
}

# -----------------------------
# Payload
# -----------------------------
$guestPayload = @{
    guests = $GuestsToAdd
} | ConvertTo-Json -Depth 5

# -----------------------------
# Endpoint
# -----------------------------
$uri = "$CalApiBase/bookings/$bookingUid/guests"

Write-StructuredLog -Level "Information" -Event "CalApiRequestPrepared" -Data @{
    bookingUid = $bookingUid
    uri = $uri
    guestCount = $GuestsToAdd.Count
}

# -----------------------------
# Call API
# -----------------------------
try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $headers `
        -Body $guestPayload

    Write-StructuredLog -Level "Information" -Event "GuestsAdded" -Data @{
        bookingUid = $bookingUid
        responseType = if ($null -ne $response) { [string]$response.GetType().FullName } else { "null" }
    }
}
catch {
    $httpStatus = $null
    $responseBody = $null

    if ($_.Exception.Response) {
        try {
            $httpStatus = [int]$_.Exception.Response.StatusCode
        }
        catch {
            $httpStatus = $null
        }

        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Dispose()
                $stream.Dispose()
            }
        }
        catch {
            $responseBody = $null
        }
    }

    Write-StructuredLog -Level "Error" -Event "GuestAddFailed" -Data @{
        bookingUid = $bookingUid
        errorMessage = [string]$_.Exception.Message
        httpStatus = $httpStatus
        responseBody = $responseBody
    }
}

return @{
    status = 200
    body   = "OK"
}
