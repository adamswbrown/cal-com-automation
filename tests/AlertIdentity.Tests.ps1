# The reconciliation table is keyed on Booking UID, and Write-NotionAlert only
# posts a comment when it CREATES a row. For a real booking that is correct:
# one unresolved gap produces one notification, not one per hourly sweep.
#
# For a synthetic event like a rules-read failure there is no booking UID, so a
# fixed literal was used. That inverts the guard -- the first failure creates the
# row and every later one silently updates it, so the alert fires once and then
# never again.
#
# Bucketing the identity by day restores the intent: a recurring failure
# notifies once a day rather than once per sweep or once per lifetime.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Modules' 'CalGuestRules' 'CalGuestRules.psd1') -Force
}

Describe 'Get-RulesFallbackAlertId' {
    It 'includes the UTC date so a new day produces a new row' {
        $id = Get-RulesFallbackAlertId -Now ([datetime]::new(2026, 9, 20, 17, 0, 0, [System.DateTimeKind]::Utc))
        $id | Should -Be 'rules-fallback-2026-09-20'
    }

    It 'is stable within the same day, so repeat sweeps update rather than spam' {
        $morning = Get-RulesFallbackAlertId -Now ([datetime]::new(2026, 9, 20, 3, 0, 0, [System.DateTimeKind]::Utc))
        $evening = Get-RulesFallbackAlertId -Now ([datetime]::new(2026, 9, 20, 23, 0, 0, [System.DateTimeKind]::Utc))
        $morning | Should -Be $evening
    }

    It 'differs across days, so a continuing outage re-notifies' {
        $day1 = Get-RulesFallbackAlertId -Now ([datetime]::new(2026, 9, 20, 23, 59, 0, [System.DateTimeKind]::Utc))
        $day2 = Get-RulesFallbackAlertId -Now ([datetime]::new(2026, 9, 21, 0, 1, 0, [System.DateTimeKind]::Utc))
        $day1 | Should -Not -Be $day2
    }

    It 'uses UTC rather than local time so the boundary is not ambiguous' {
        # 00:30 UTC on the 21st is still the 20th in some local zones. The id
        # must follow UTC, matching how every other timestamp here is recorded.
        $id = Get-RulesFallbackAlertId -Now ([datetime]::new(2026, 9, 21, 0, 30, 0, [System.DateTimeKind]::Utc))
        $id | Should -Be 'rules-fallback-2026-09-21'
    }

    It 'defaults to now when no time is supplied' {
        $id = Get-RulesFallbackAlertId
        $id | Should -Match '^rules-fallback-\d{4}-\d{2}-\d{2}$'
    }
}
