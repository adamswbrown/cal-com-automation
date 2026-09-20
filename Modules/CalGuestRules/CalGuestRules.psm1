# Guest rules for Cal.com bookings.
#
# Rules are data, not logic: each entry pairs a match predicate with the guests
# that rule contributes. A booking's expected guests are the union across every
# rule whose predicate returns true. Add a rule by adding a table entry.
#
# This module is imported by both the cal-automation webhook and the
# cal-reconcile timer, so there is exactly one answer to "who belongs on this
# booking?" and no way for the two to drift apart.
$script:GuestRules = @(
    @{
        name   = 'always'
        match  = { param($Booking) $true }
        guests = @(
            [pscustomobject]@{ email = 'Sandra.Murray@altra.cloud'; name = 'Sandra Murray' }
        )
    },
    @{
        name   = 'white-glove'
        match  = { param($Booking) $Booking.Slug -like '*white-glove*' }
        guests = @(
            [pscustomobject]@{ email = 'luke.lloyd@altra.cloud'; name = 'Luke Lloyd' },
            [pscustomobject]@{ email = 'Joey.Undis@altra.cloud'; name = 'Joey Undis' }
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
