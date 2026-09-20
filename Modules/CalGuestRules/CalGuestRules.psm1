# Guest rules for Cal.com bookings.
#
# Rules are data, not logic: each entry pairs a match predicate with the guests
# that rule contributes. A booking's expected guests are the union across every
# rule whose predicate returns true. Add a rule by adding a table entry.
#
# This module is imported by both the cal-automation webhook and the
# cal-reconcile timer, so there is exactly one answer to "who belongs on this
# booking?" and no way for the two to drift apart.
$script:BuiltInRules = @(
    [pscustomobject]@{
        name      = 'Always add Sandra'
        matchType = 'Always'
        match     = ''
        guests    = @(
            [pscustomobject]@{ email = 'Sandra.Murray@altra.cloud'; name = 'Sandra Murray' }
        )
    },
    [pscustomobject]@{
        name      = 'White glove sessions'
        matchType = 'Slug contains'
        match     = 'white-glove'
        guests    = @(
            [pscustomobject]@{ email = 'luke.lloyd@altra.cloud'; name = 'Luke Lloyd' },
            [pscustomobject]@{ email = 'Joey.Undis@altra.cloud'; name = 'Joey Undis' }
        )
    }
)

function Get-BuiltInGuestRules {
    <#
        .SYNOPSIS
        The fallback rule set, used when the Notion table is unreachable or empty.
        Kept deliberately identical to the seeded Notion rows so a fallback is a
        no-op rather than a behaviour change.
    #>
    @($script:BuiltInRules)
}

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

function Test-RuleMatchesBooking {
    <#
        .SYNOPSIS
        Evaluates one rule against one booking. Unknown match types never match,
        so a typo in Notion silently adds nobody rather than adding everybody.
    #>
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)]$Booking
    )

    switch ($Rule.matchType) {
        'Always' { return $true }
        'Slug contains' {
            if ([string]::IsNullOrWhiteSpace($Rule.match)) { return $false }
            return ([string]$Booking.Slug).ToLowerInvariant().Contains(([string]$Rule.match).ToLowerInvariant())
        }
        'Slug exact' {
            return ([string]$Booking.Slug) -ieq ([string]$Rule.match)
        }
        'Customer contains' {
            if ([string]::IsNullOrWhiteSpace($Rule.match)) { return $false }
            if ([string]::IsNullOrWhiteSpace($Booking.CustomerCompany)) { return $false }
            return ([string]$Booking.CustomerCompany).ToLowerInvariant().Contains(([string]$Rule.match).ToLowerInvariant())
        }
        default { return $false }
    }
}

function Get-ExpectedGuests {
    <#
        .SYNOPSIS
        Returns every guest the rules say belongs on this booking.

        .PARAMETER Rules
        The rule set to evaluate. Defaults to the built-in fallback rules so
        existing callers and tests keep working without a Notion round-trip.
    #>
    param(
        [Parameter(Mandatory)]$Booking,
        $Rules
    )

    if (-not $Rules) { $Rules = Get-BuiltInGuestRules }

    $expected = [ordered]@{}

    foreach ($rule in @($Rules)) {
        if (Test-RuleMatchesBooking -Rule $rule -Booking $Booking) {
            foreach ($guest in @($rule.guests)) {
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
    param(
        [Parameter(Mandatory)]$Booking,
        $Rules
    )

    @(Get-ExpectedGuests -Booking $Booking -Rules $Rules |
        Where-Object { $Booking.ActualGuestEmails -notcontains $_.email.ToLowerInvariant() })
}


function Get-RulesFallbackAlertId {
    <#
        .SYNOPSIS
        Identity for the synthetic "rules could not be read" alert row.

        .DESCRIPTION
        Write-NotionAlert only comments when it creates a row, which keeps one
        booking gap to one notification. A fixed id for a recurring synthetic
        event inverts that: the first failure creates the row, every later one
        silently updates it, and the alert never fires again.

        Bucketing by UTC date means a continuing outage re-notifies once a day
        rather than once per sweep or once per lifetime.
    #>
    param([datetime]$Now = (Get-Date).ToUniversalTime())

    'rules-fallback-' + $Now.ToUniversalTime().ToString('yyyy-MM-dd')
}

# -----------------------------------------------------------------------------
# Notion rule parsing
#
# Pure functions: they take an already-fetched Notion response and turn it into
# the same rule shape as the built-ins. The HTTP call lives in NotionRules, so
# everything here stays unit-testable without a network.
# -----------------------------------------------------------------------------

function ConvertTo-GuestDisplayName {
    <#
        .SYNOPSIS
        Derives a display name from an email local part.

        .DESCRIPTION
        Altra addresses follow firstname.lastname, so the name is recoverable
        from the address and nobody has to type it twice. An address with no
        separator yields the local part title-cased.
    #>
    param([Parameter(Mandatory)][string]$Email)

    $local = ($Email -split '@')[0]
    $parts = $local -split '[._-]+' | Where-Object { $_ }

    $titled = $parts | ForEach-Object {
        if ($_.Length -eq 1) { $_.ToUpperInvariant() }
        else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
    }

    ($titled -join ' ')
}

function ConvertFrom-GuestOption {
    <#
        .SYNOPSIS
        Turns one multi-select option into an email/name pair.

        .DESCRIPTION
        A bare address gets a derived name. The "Name <email>" form is the
        escape hatch for addresses that do not follow firstname.lastname.
        An option containing no address returns nothing, so one bad entry is
        skipped rather than poisoning the rule.
    #>
    param([Parameter(Mandatory)][string]$Option)

    $trimmed = $Option.Trim()

    if ($trimmed -match '^(?<name>.*?)\s*<(?<email>[^>]+)>$') {
        $email = $Matches['email'].Trim()
        $name = $Matches['name'].Trim()
        if (-not $email.Contains('@')) { return }
        if (-not $name) { $name = ConvertTo-GuestDisplayName -Email $email }
        return [pscustomobject]@{ email = $email; name = $name }
    }

    if (-not $trimmed.Contains('@')) { return }

    [pscustomobject]@{
        email = $trimmed
        name  = ConvertTo-GuestDisplayName -Email $trimmed
    }
}

function ConvertFrom-NotionRulesResponse {
    <#
        .SYNOPSIS
        Turns a Notion database query response into a rule set.

        .DESCRIPTION
        Skips inactive rows, rows with no match type, and rows that resolve to no
        usable guests. One malformed row is dropped rather than failing the whole
        set, because a single typo should not void every rule.
    #>
    param([Parameter(Mandatory)]$Response)

    $rules = @()

    foreach ($row in @($Response.results)) {
        $props = $row.properties
        if (-not $props) { continue }

        if ($props.Active.checkbox -ne $true) { continue }

        $matchType = [string]$props.'Match Type'.select.name
        if ([string]::IsNullOrWhiteSpace($matchType)) { continue }

        $guests = @()
        foreach ($option in @($props.Guests.multi_select)) {
            $guest = ConvertFrom-GuestOption -Option ([string]$option.name)
            if ($guest) { $guests += $guest }
        }
        if ($guests.Count -eq 0) { continue }

        $name = [string](@($props.Rule.title).plain_text -join '')
        $match = [string](@($props.Match.rich_text).plain_text -join '')

        $rules += [pscustomobject]@{
            name      = $name
            matchType = $matchType
            match     = $match
            guests    = $guests
        }
    }

    @($rules)
}

Export-ModuleMember -Function ConvertFrom-CalBooking, ConvertFrom-CalWebhookPayload, Get-ExpectedGuests, Get-MissingGuests, Get-BuiltInGuestRules, ConvertTo-GuestDisplayName, ConvertFrom-GuestOption, ConvertFrom-NotionRulesResponse, Get-RulesFallbackAlertId
