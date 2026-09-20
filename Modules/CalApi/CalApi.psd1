@{
    RootModule        = 'CalApi.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c2a3b4d5-6f70-4b81-9c2d-1e2f3a4b5c6d'
    Author            = 'Altra'
    Description       = 'Thin wrappers over the Cal.com v2 REST API.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Get-CalUpcomingBookings', 'Add-CalBookingGuests')
}
