@{
    RootModule        = 'NotionRules.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e4c5d6f7-8192-4da3-9e4f-3a4b5c6d7e8f'
    Author            = 'Altra'
    Description       = 'Fetches guest rules from Notion with a cold-start cache and a built-in fallback.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Get-NotionGuestRules', 'Clear-NotionGuestRulesCache')
}
