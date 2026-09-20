BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'Modules' 'CalGuestRules' 'CalGuestRules.psm1'
    Import-Module $script:ModulePath -Force

    $script:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'
    $script:WhiteGlove = Get-Content (Join-Path $script:FixtureDir 'booking-white-glove.json') -Raw | ConvertFrom-Json
    $script:PartnerIntro = Get-Content (Join-Path $script:FixtureDir 'booking-partner-intro.json') -Raw | ConvertFrom-Json
    $script:Webhook = Get-Content (Join-Path $script:FixtureDir 'webhook-white-glove.json') -Raw | ConvertFrom-Json
}

Describe 'ConvertFrom-CalBooking' {
    It 'extracts the fields the rules need' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $b.Uid | Should -Be '8QUGCCgAWACpqQBmksPwUw'
        $b.Slug | Should -Be 'white-glove-session'
        $b.CustomerCompany | Should -Be 'Ecclesiastical Insurance'
        $b.StartUtc | Should -BeOfType [datetime]
    }

    It 'lowercases actual guest emails and includes attendees' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        $b.ActualGuestEmails | Should -Contain 'sandra.murray@altra.cloud'
        $b.ActualGuestEmails | Should -Contain 'errolmc@softcat.com'
    }

    It 'does not duplicate an email present in both attendees and guests' {
        $b = ConvertFrom-CalBooking -Booking $script:WhiteGlove
        @($b.ActualGuestEmails | Where-Object { $_ -eq 'sandra.murray@altra.cloud' }).Count | Should -Be 1
    }
}

Describe 'ConvertFrom-CalWebhookPayload' {
    It 'normalises the webhook shape to the same contract' {
        $b = ConvertFrom-CalWebhookPayload -Payload $script:Webhook.payload
        $b.Uid | Should -Be '8QUGCCgAWACpqQBmksPwUw'
        $b.Slug | Should -Be 'white-glove-session'
        $b.CustomerCompany | Should -Be 'Ecclesiastical Insurance'
    }

    It 'produces the same expected guests as the list-API shape' {
        $fromWebhook = Get-ExpectedGuests -Booking (ConvertFrom-CalWebhookPayload -Payload $script:Webhook.payload)
        $fromList = Get-ExpectedGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        ($fromWebhook.email | Sort-Object) | Should -Be ($fromList.email | Sort-Object)
    }
}

Describe 'Get-ExpectedGuests' {
    It 'returns three guests for a white-glove booking' {
        $g = Get-ExpectedGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        @($g).Count | Should -Be 3
        $g.email | Should -Contain 'Sandra.Murray@altra.cloud'
        $g.email | Should -Contain 'luke.lloyd@altra.cloud'
        $g.email | Should -Contain 'Joey.Undis@altra.cloud'
    }

    It 'returns only the always-guest for a non-white-glove booking' {
        $g = Get-ExpectedGuests -Booking (ConvertFrom-CalBooking -Booking $script:PartnerIntro)
        @($g).Count | Should -Be 1
        $g.email | Should -Be 'Sandra.Murray@altra.cloud'
    }
}

Describe 'Get-MissingGuests' {
    It 'reports the two white-glove guests as missing' {
        $m = Get-MissingGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        @($m).Count | Should -Be 2
        $m.email | Should -Contain 'luke.lloyd@altra.cloud'
        $m.email | Should -Contain 'Joey.Undis@altra.cloud'
    }

    It 'matches case-insensitively so Sandra is not reported missing' {
        $m = Get-MissingGuests -Booking (ConvertFrom-CalBooking -Booking $script:WhiteGlove)
        $m.email | Should -Not -Contain 'Sandra.Murray@altra.cloud'
    }

    It 'returns nothing when every expected guest is present' {
        $m = Get-MissingGuests -Booking (ConvertFrom-CalBooking -Booking $script:PartnerIntro)
        @($m).Count | Should -Be 0
    }
}
