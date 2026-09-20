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
