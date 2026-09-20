@{
    RootModule        = 'NotionAlert.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd3b4c5e6-7081-4c92-8d3e-2f3a4b5c6d7e'
    Author            = 'Altra'
    Description       = 'Writes reconciliation results to a Notion database and notifies via comment mention.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Write-NotionAlert')
}
