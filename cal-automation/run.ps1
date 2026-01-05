param($Request, $TriggerMetadata)

Write-Host "Cal.com webhook received"

# -----------------------------
# Config
# -----------------------------
[string]$CalApiBase       = "https://api.cal.com/v2"
[string]$SalesGuestEmail  = "Sandra.Murray@altra.cloud"   # CHANGE IF NEEDED
[string]$SalesGuestName   = "Sales Team"

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

if (-not $body -or -not $body.booking -or -not $body.booking.uid) {
    Write-Host "Invalid webhook payload"
    return @{
        status = 400
        body   = "Invalid webhook payload"
    }
}

[string]$bookingUid = $body.booking.uid
[string]$eventTitle = $body.booking.title

Write-Host ("Processing booking UID: {0}" -f $bookingUid)
Write-Host ("Event title: {0}" -f $eventTitle)

# -----------------------------
# Build headers
# -----------------------------
$headers = @{
    "Authorization"   = ("Bearer {0}" -f $ApiKey)
    "Content-Type"    = "application/json"
    "cal-api-version" = "2"
}

# -----------------------------
# Build guest payload
# -----------------------------
$guestPayload = @{
    email = $SalesGuestEmail
    name  = $SalesGuestName
} | ConvertTo-Json -Depth 3

# -----------------------------
# Build request URI safely
# -----------------------------
$uri = "{0}/bookings/{1}/guests" -f $CalApiBase, $bookingUid

# -----------------------------
# Call Cal.com API
# -----------------------------
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
    # Intentionally swallow errors to prevent webhook retries
}

# -----------------------------
# Done
# -----------------------------
return @{
    status = 200
    body   = "OK"
}