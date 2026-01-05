param($Request, $TriggerMetadata)

Write-Host "Webhook received"

return @{
    status = 200
    body   = "OK"
}