# These tests import modules BY NAME through PSModulePath, exactly as the
# Azure Functions host does via profile.ps1 -- not by .psm1 path.
#
# Importing by path bypasses the manifest, so a function missing from
# FunctionsToExport still resolves locally and fails only in production. That
# is precisely the gap that shipped ConvertFrom-NotionRulesResponse as
# unresolvable. Every test here goes through the manifest.

BeforeAll {
    $script:ModulesRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Modules')).Path
}

Describe 'Module manifests' {
    It 'CalGuestRules exports every function the module exports' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:ModulesRoot 'CalGuestRules' 'CalGuestRules.psd1')
        $psm1 = Get-Content (Join-Path $script:ModulesRoot 'CalGuestRules' 'CalGuestRules.psm1') -Raw

        $exportLine = ($psm1 -split "`n" | Where-Object { $_ -match '^Export-ModuleMember' })
        $exported = ($exportLine -replace '^Export-ModuleMember\s+-Function\s+', '') -split ',' |
            ForEach-Object { $_.Trim() } | Where-Object { $_ }

        foreach ($fn in $exported) {
            $manifest.FunctionsToExport | Should -Contain $fn -Because "$fn is exported by the .psm1 but the manifest would hide it from Import-Module by name"
        }
    }
}

Describe 'Cross-module resolution as the Functions host does it' {
    It 'resolves CalGuestRules functions from inside NotionRules' {
        # Run in a child process with a clean PSModulePath so this mirrors a
        # cold start rather than inheriting anything this session imported.
        $script = @"
`$env:PSModulePath = '$($script:ModulesRoot)' + [System.IO.Path]::PathSeparator + `$env:PSModulePath
Import-Module CalGuestRules -ErrorAction Stop
Import-Module NotionRules -ErrorAction Stop
`$r = Get-NotionGuestRules -Token '' -DatabaseId ''
if (`$null -eq `$r) { 'NULL_RESULT'; exit }
if (-not `$r.Fallback) { 'EXPECTED_FALLBACK'; exit }
if (@(`$r.Rules).Count -lt 1) { 'NO_RULES'; exit }
'OK:' + @(`$r.Rules).Count
"@
        $result = pwsh -NoProfile -Command $script 2>&1 | Select-Object -Last 1
        $result | Should -Match '^OK:\d+$'
    }

    It 'parses a Notion response through a by-name import' {
        $fixture = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'notion-rules-response.json')).Path
        $script = @"
`$env:PSModulePath = '$($script:ModulesRoot)' + [System.IO.Path]::PathSeparator + `$env:PSModulePath
Import-Module CalGuestRules -ErrorAction Stop
`$response = Get-Content '$fixture' -Raw | ConvertFrom-Json
`$rules = @(ConvertFrom-NotionRulesResponse -Response `$response)
'OK:' + `$rules.Count
"@
        $result = pwsh -NoProfile -Command $script 2>&1 | Select-Object -Last 1
        $result | Should -Be 'OK:3'
    }
}
