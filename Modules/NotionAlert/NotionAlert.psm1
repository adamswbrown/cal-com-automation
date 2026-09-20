$script:NotionApiBase = 'https://api.notion.com/v1'
$script:NotionVersion = '2022-06-28'

function Get-NotionHeaders {
    param([Parameter(Mandatory)][string]$Token)
    @{
        Authorization    = "Bearer $Token"
        'Notion-Version' = $script:NotionVersion
        'Content-Type'   = 'application/json'
    }
}

function Find-NotionOpenRow {
    <#
        .SYNOPSIS
        Finds an existing unresolved row for this booking, so repeat sweeps update
        in place instead of creating a row per hour.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DatabaseId,
        [Parameter(Mandatory)][string]$BookingUid
    )

    $filter = @{
        filter    = @{
            and = @(
                @{ property = 'Booking UID'; rich_text = @{ equals = $BookingUid } },
                @{ property = 'Status'; select = @{ does_not_equal = 'Auto-fixed' } }
            )
        }
        page_size = 1
    } | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Method Post `
        -Uri "$script:NotionApiBase/databases/$DatabaseId/query" `
        -Headers (Get-NotionHeaders -Token $Token) `
        -Body $filter

    if ($response.results -and @($response.results).Count -gt 0) {
        return $response.results[0].id
    }
    return $null
}

function Write-NotionAlert {
    <#
        .SYNOPSIS
        Records a reconciliation result as a Notion row, commenting to notify when
        a human needs to act.

        .DESCRIPTION
        Never throws. Notion is a notification channel, not the system of record --
        a Notion outage must not fail the sweep, because App Insights already holds
        the authoritative log line.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DatabaseId,
        [string]$MentionUserId,
        [Parameter(Mandatory)][ValidateSet('Auto-fixed', 'Needs action', 'Failed')][string]$Status,
        [Parameter(Mandatory)]$Booking,
        [array]$MissingGuests = @(),
        [string]$Detail = ''
    )

    try {
        $missingText = (@($MissingGuests) | ForEach-Object { [string]$_.email }) -join ', '
        $headers = Get-NotionHeaders -Token $Token

        $existingPageId = Find-NotionOpenRow -Token $Token -DatabaseId $DatabaseId -BookingUid $Booking.Uid

        $properties = @{
            'Booking'        = @{ title = @(@{ text = @{ content = [string]$Booking.Title } }) }
            'Status'         = @{ select = @{ name = $Status } }
            'Booking UID'    = @{ rich_text = @(@{ text = @{ content = [string]$Booking.Uid } }) }
            'Starts'         = @{ date = @{ start = $Booking.StartUtc.ToString('o') } }
            'Missing Guests' = @{ rich_text = @(@{ text = @{ content = $missingText } }) }
            'Event Type'     = @{ rich_text = @(@{ text = @{ content = [string]$Booking.Slug } }) }
            'Customer'       = @{ rich_text = @(@{ text = @{ content = [string]$Booking.CustomerCompany } }) }
            'Booking URL'    = @{ url = "https://app.cal.com/booking/$($Booking.Uid)" }
        }

        $created = $false

        if ($existingPageId) {
            $body = @{ properties = $properties } | ConvertTo-Json -Depth 10
            $null = Invoke-RestMethod -Method Patch -Uri "$script:NotionApiBase/pages/$existingPageId" -Headers $headers -Body $body
            $pageId = $existingPageId
        }
        else {
            $body = @{
                parent     = @{ database_id = $DatabaseId }
                properties = $properties
            } | ConvertTo-Json -Depth 10
            $page = Invoke-RestMethod -Method Post -Uri "$script:NotionApiBase/pages" -Headers $headers -Body $body
            $pageId = $page.id
            $created = $true
        }

        # Comment only on a newly created row that needs a human. Updating an
        # existing open row must stay silent or an hourly sweep becomes a siren.
        $commented = $false
        if ($created -and $Status -ne 'Auto-fixed' -and $MentionUserId) {
            $summary = if ($Status -eq 'Failed') {
                "Could not add guests to this booking. $Detail"
            }
            else {
                "Starts within 24h, so guests were not auto-added. Missing: $missingText"
            }

            $commentBody = @{
                parent    = @{ page_id = $pageId }
                rich_text = @(
                    @{ type = 'mention'; mention = @{ type = 'user'; user = @{ id = $MentionUserId } } },
                    @{ type = 'text'; text = @{ content = " $summary" } }
                )
            } | ConvertTo-Json -Depth 10

            $null = Invoke-RestMethod -Method Post -Uri "$script:NotionApiBase/comments" -Headers $headers -Body $commentBody
            $commented = $true
        }

        return @{ Success = $true; PageId = $pageId; Created = $created; Commented = $commented; Error = $null }
    }
    catch {
        return @{ Success = $false; PageId = $null; Created = $false; Commented = $false; Error = [string]$_.Exception.Message }
    }
}

Export-ModuleMember -Function Write-NotionAlert
