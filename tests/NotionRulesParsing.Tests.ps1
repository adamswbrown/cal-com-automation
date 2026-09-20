BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Modules' 'CalGuestRules' 'CalGuestRules.psm1') -Force

    $script:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'
    $script:Response = Get-Content (Join-Path $script:FixtureDir 'notion-rules-response.json') -Raw | ConvertFrom-Json
    $script:WhiteGlove = Get-Content (Join-Path $script:FixtureDir 'booking-white-glove.json') -Raw | ConvertFrom-Json
    $script:PartnerIntro = Get-Content (Join-Path $script:FixtureDir 'booking-partner-intro.json') -Raw | ConvertFrom-Json
}

Describe 'ConvertTo-GuestDisplayName' {
    It 'derives a name from a firstname.lastname address' {
        ConvertTo-GuestDisplayName -Email 'luke.lloyd@altra.cloud' | Should -Be 'Luke Lloyd'
    }

    It 'title-cases regardless of the casing used in the address' {
        ConvertTo-GuestDisplayName -Email 'Sandra.Murray@altra.cloud' | Should -Be 'Sandra Murray'
        ConvertTo-GuestDisplayName -Email 'Joey.Undis@altra.cloud' | Should -Be 'Joey Undis'
    }

    It 'handles underscore and hyphen separators' {
        ConvertTo-GuestDisplayName -Email 'anne_marie@altra.cloud' | Should -Be 'Anne Marie'
        ConvertTo-GuestDisplayName -Email 'jean-paul@altra.cloud' | Should -Be 'Jean Paul'
    }

    It 'falls back to the local part when there is no separator' {
        ConvertTo-GuestDisplayName -Email 'errolmc@softcat.com' | Should -Be 'Errolmc'
    }
}

Describe 'ConvertFrom-GuestOption' {
    It 'treats a bare address as an email with a derived name' {
        $g = ConvertFrom-GuestOption -Option 'luke.lloyd@altra.cloud'
        $g.email | Should -Be 'luke.lloyd@altra.cloud'
        $g.name | Should -Be 'Luke Lloyd'
    }

    It 'parses the Name <email> escape hatch' {
        $g = ConvertFrom-GuestOption -Option 'Partner Desk <info@partner.com>'
        $g.email | Should -Be 'info@partner.com'
        $g.name | Should -Be 'Partner Desk'
    }

    It 'returns nothing for an option with no address' {
        ConvertFrom-GuestOption -Option 'not an email' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-NotionRulesResponse' {
    It 'returns only active, well-formed rules' {
        $rules = @(ConvertFrom-NotionRulesResponse -Response $script:Response)
        $rules.Count | Should -Be 3
        $rules.name | Should -Not -Contain 'Retired rule'
        $rules.name | Should -Not -Contain 'Broken rule'
    }

    It 'preserves the match type and term' {
        $rules = @(ConvertFrom-NotionRulesResponse -Response $script:Response)
        $wg = $rules | Where-Object { $_.name -eq 'White glove sessions' }
        $wg.matchType | Should -Be 'Slug contains'
        $wg.match | Should -Be 'white-glove'
    }

    It 'resolves multi-select guests into email and name pairs' {
        $rules = @(ConvertFrom-NotionRulesResponse -Response $script:Response)
        $wg = $rules | Where-Object { $_.name -eq 'White glove sessions' }
        @($wg.guests).Count | Should -Be 2
        $wg.guests.email | Should -Contain 'luke.lloyd@altra.cloud'
        ($wg.guests | Where-Object { $_.email -eq 'luke.lloyd@altra.cloud' }).name | Should -Be 'Luke Lloyd'
    }

    It 'returns an empty set for a response with no results' {
        @(ConvertFrom-NotionRulesResponse -Response ([pscustomobject]@{ results = @() })) | Should -BeNullOrEmpty
    }
}

Describe 'Get-ExpectedGuests with Notion-sourced rules' {
    BeforeAll {
        $script:NotionRules = @(ConvertFrom-NotionRulesResponse -Response $script:Response)
    }

    It 'reproduces every built-in guest for a white-glove booking' {
        # The fixture carries an extra Customer rule the built-ins do not have,
        # so this asserts parity on the seeded rules rather than exact equality.
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $fromNotion = Get-ExpectedGuests -Booking $b -Rules $script:NotionRules
        $fromBuiltIn = Get-ExpectedGuests -Booking $b

        foreach ($email in $fromBuiltIn.email) {
            $fromNotion.email | Should -Contain $email
        }
    }

    It 'matches the built-ins exactly when given the equivalent rule set' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $seeded = @($script:NotionRules | Where-Object { $_.matchType -ne 'Customer contains' })
        $fromNotion = Get-ExpectedGuests -Booking $b -Rules $seeded
        $fromBuiltIn = Get-ExpectedGuests -Booking $b
        ($fromNotion.email | Sort-Object) | Should -Be ($fromBuiltIn.email | Sort-Object)
    }

    It 'applies a Customer contains rule' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $g = Get-ExpectedGuests -Booking $b -Rules $script:NotionRules
        $g.email | Should -Contain 'info@partner.com'
    }

    It 'does not apply the Customer rule to a non-matching booking' {
        $b = ConvertFrom-CalBooking -Booking $script:PartnerIntro
        $g = Get-ExpectedGuests -Booking $b -Rules $script:NotionRules
        $g.email | Should -Not -Contain 'info@partner.com'
        @($g).Count | Should -Be 1
    }

    It 'supports Slug exact as distinct from Slug contains' {
        $exactRules = @(
            [pscustomobject]@{
                name = 'exact'; matchType = 'Slug exact'; match = 'white-glove-session'
                guests = @([pscustomobject]@{ email = 'x@altra.cloud'; name = 'X' })
            }
        )
        $wg = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        (Get-ExpectedGuests -Booking $wg -Rules $exactRules).email | Should -Be 'x@altra.cloud'

        $partial = @(
            [pscustomobject]@{
                name = 'exact'; matchType = 'Slug exact'; match = 'white-glove'
                guests = @([pscustomobject]@{ email = 'x@altra.cloud'; name = 'X' })
            }
        )
        @(Get-ExpectedGuests -Booking $wg -Rules $partial) | Should -BeNullOrEmpty
    }
}
