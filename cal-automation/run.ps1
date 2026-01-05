param($Request, $TriggerMetadata)

Write-Host "Cal.com webhook received"

# -----------------------------
# Config
# -----------------------------
[string]$CalApiBase      = "https://api.cal.com/v2"
[string]$SalesGuestEmail = "Sandra.Murray@altra.cloud"
[string]$SalesGuestName  = "Sales Team"

# IMPORTANT: exact casing
$ApiKey = $env:CAL_API_KEY
if (-not $ApiKey) {
    Write-Host "CAL_API_KEY not set"
    return @{
        status = 500
        body   = "CAL_API_KEY not configured"
    }
}

# -----------------------------
# Parse request body
# -----------------------------
$body = $Request.Body

# Temporary raw logging (keep this until confirmed working)
Write-Host "RAW WEBHOOK BODY:"
$body | ConvertTo-Json -Depth 10 | Write-Host

# -----------------------------
# Extract booking UID safely
# -----------------------------
$bookingUid =
    $body.booking.uid `
    ?? $body.payload.booking.uid `
    ?? $body.data.uid `
    ?? $body.payload.uid

$eventTitle =
    $body.booking.title `
    ?? $body.payload.booking.title `
    ?? $body.data.eventType.title `
    ?? "Unknown Event"

if (-not $bookingUid) {
    Write-Host "Booking UID not found in payload"
    return @{
        status = 400
        body   = "Booking UID missing"
    }
}

Write-Host ("Processing booking UID: {0}" -f $bookingUid)
Write-Host ("Event title: {0}" -f $eventTitle)

# -----------------------------
# Build headers
# -----------------------------
$headers = @{
    Authorization     = "Bearer $ApiKey"
    "Content-Type"    = "application/json"
    "cal-api-version" = "2024-08-13"
}

# -----------------------------
# Guest payload
# -----------------------------
$guestPayload = @{
    email = $SalesGuestEmail
    name  = $SalesGuestName
} | ConvertTo-Json -Depth 3

# -----------------------------
# Call Cal.com API
# -----------------------------
$uri = "$CalApiBase/bookings/$bookingUid/guests"

try {
    Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $headers `
        -Body $guestPayload

    Write-Host "Guest added successfully"
}
catch {
    Write-Host "Guest add failed or already exists"
    Write-Host $_.Exception.Message
}

# -----------------------------
# Done
# -----------------------------
return @{
    status = 200
    body   = "OK"
}