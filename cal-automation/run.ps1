param($Request, $TriggerMetadata)

Write-Host "Cal.com webhook received"

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
    Write-Host "CAL_API_KEY not set"
    return @{
        status = 500
        body   = "CAL_API_KEY not configured"
    }
}

# -----------------------------
# Parse webhook payload
# -----------------------------
$body = $Request.Body

# Cal webhook payload shape
$bookingUid = $body.payload.uid

if (-not $bookingUid) {
    Write-Host "Invalid webhook payload – booking UID missing"
    return @{
        status = 400
        body   = "Invalid webhook payload"
    }
}

Write-Host "Processing booking UID: $bookingUid"

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
    Write-Host "White glove kickoff booking detected, adding Luke and Joey"
    $GuestsToAdd += $WhiteGloveGuestsToAdd
}

# -----------------------------
# Headers (CRITICAL)
# -----------------------------
$headers = @{
    Authorization    = "Bearer $ApiKey"
    "Content-Type"   = "application/json"
    "cal-api-version"= "2024-08-13"   # 🔴 MUST MATCH DOCS
}

# -----------------------------
# Payload (array required)
# -----------------------------
$guestPayload = @{
    guests = $GuestsToAdd
} | ConvertTo-Json -Depth 5

# -----------------------------
# Endpoint
# -----------------------------
$uri = "$CalApiBase/bookings/$bookingUid/guests"

# -----------------------------
# Call API
# -----------------------------
try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $headers `
        -Body $guestPayload

    Write-Host "Guests added successfully"
}
catch {
    Write-Host "Guest add failed"
    Write-Host $_.Exception.Message
}

return @{
    status = 200
    body   = "OK"
}
