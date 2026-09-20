@{
    RootModule        = 'CalGuestRules.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d'
    Author            = 'Altra'
    Description       = 'Guest rules and booking normalisation shared by the Cal.com webhook and reconciler.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'ConvertFrom-CalBooking',
        'ConvertFrom-CalWebhookPayload',
        'Get-ExpectedGuests',
        'Get-MissingGuests'
    )
}
