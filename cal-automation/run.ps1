param($Request, $TriggerMetadata)

# -----------------------------
# Logging helpers
# -----------------------------
$invocationId = [string]$TriggerMetadata.sys.RandGuid
if (-not $invocationId) {
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

$DefaultGuestsToAdd = @(
    @{
        email = "Sandra.Murray@altra.cloud"
        name  = "Sandra Murray"
    }
)

$WhiteGloveGuestsToAdd = @(
    @{
        email = "luke.lloyd@altra.cloud"
        name  = "Luke Lloyd"
    },
    @{
        email = "Joey.Undis@altra.cloud"
        name  = "Joey Undis"
    }
)

$WhiteGloveSlug = "dr-migrate-white-glove-kickoff"

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

# Add extra people for white glove kickoff bookings.
$GuestsToAdd = @($DefaultGuestsToAdd)
$whiteGloveSignalFields = @(
    [string]$body.payload.eventType.slug,
    [string]$body.payload.eventType.title,
    [string]$body.payload.eventType.name,
    [string]$body.payload.eventTypeUrl,
    [string]$body.payload.bookingUrl,
    [string]$body.payload.location
)
$isWhiteGloveBooking = ($whiteGloveSignalFields | Where-Object {
    $_ -and $_.ToLower().Contains($WhiteGloveSlug)
}).Count -gt 0

if ($isWhiteGloveBooking) {
    $GuestsToAdd += $WhiteGloveGuestsToAdd
}

Write-StructuredLog -Level "Information" -Event "GuestSelection" -Data @{
    bookingUid = $bookingUid
    isWhiteGloveBooking = $isWhiteGloveBooking
    guestCount = $GuestsToAdd.Count
    guests = @($GuestsToAdd | ForEach-Object { [string]$_.email })
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
