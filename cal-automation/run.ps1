param($Request, $TriggerMetadata)

Write-Host "Cal.com webhook received"

# -----------------------------
# Config
# -----------------------------
$CalApiBase = "https://api.cal.com/v2"

$GuestsToAdd = @(
    @{
        email = "Sandra.Murray@altra.cloud"
        name  = "Sandra Murray"
    }
)

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