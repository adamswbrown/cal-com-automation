$script:NotionApiBase = 'https://api.notion.com/v1'
$script:NotionVersion = '2022-06-28'

# Cached for the life of the worker instance. $script: scope survives across
# invocations on the same instance, so this is a cold-start cache with no extra
# machinery. A rule change in Notion goes live on the next cold start.
$script:CachedRules = $null
$script:CacheSource = $null

function Clear-NotionGuestRulesCache {
    <#
        .SYNOPSIS
        Drops the cached rules so the next call refetches. Exists for tests and
        for a future forced-refresh trigger.
    #>
    $script:CachedRules = $null
    $script:CacheSource = $null
}

function Get-NotionGuestRules {
    <#
        .SYNOPSIS
        Returns the guest rules, preferring Notion and falling back to the
        built-in set.

        .DESCRIPTION
        Never throws. A rules lookup that fails must degrade to today's behaviour
        rather than taking down the webhook, so every failure path returns the
        built-in rules and reports what happened.

        .OUTPUTS
        @{ Rules = <rule[]>; Source = 'notion'|'builtin'|'cache'; Fallback = [bool]; Error = [string] }
    #>
    param(
        [string]$Token,
        [string]$DatabaseId,
        [scriptblock]$Logger
    )

    if ($null -ne $script:CachedRules) {
        return @{ Rules = $script:CachedRules; Source = $script:CacheSource; Fallback = $false; Error = $null }
    }

    $builtIn = Get-BuiltInGuestRules

    if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($DatabaseId)) {
        return @{ Rules = $builtIn; Source = 'builtin'; Fallback = $true; Error = 'NOTION_TOKEN or NOTION_RULES_DB_ID not configured' }
    }

    try {
        $headers = @{
            Authorization    = "Bearer $Token"
            'Notion-Version' = $script:NotionVersion
            'Content-Type'   = 'application/json'
        }

        $body = @{ page_size = 100 } | ConvertTo-Json

        $response = Invoke-RestMethod -Method Post `
            -Uri "$script:NotionApiBase/databases/$DatabaseId/query" `
            -Headers $headers `
            -Body $body

        $rules = @(ConvertFrom-NotionRulesResponse -Response $response)

        if ($rules.Count -eq 0) {
            return @{ Rules = $builtIn; Source = 'builtin'; Fallback = $true; Error = 'Notion rules table returned no usable rules' }
        }

        $script:CachedRules = $rules
        $script:CacheSource = 'notion'

        return @{ Rules = $rules; Source = 'notion'; Fallback = $false; Error = $null }
    }
    catch {
        return @{ Rules = $builtIn; Source = 'builtin'; Fallback = $true; Error = [string]$_.Exception.Message }
    }
}

Export-ModuleMember -Function Get-NotionGuestRules, Clear-NotionGuestRulesCache
