<#
.SYNOPSIS
    Generates a mailbox report with size, permissions, and delegate info.

.DESCRIPTION
    Connects to Exchange Online and pulls mailbox statistics, folder permissions,
    and delegate access. Exports formatted Excel report.

.PARAMETER MailboxType
    Filter by mailbox type. Valid: All, User, Shared. Default: All

.EXAMPLE
    .\Get-MailboxReport.ps1
    Reports on all mailboxes.

.EXAMPLE
    .\Get-MailboxReport.ps1 -MailboxType Shared
    Reports on shared mailboxes only.
#>

param(
    [ValidateSet("All", "User", "Shared")]
    [string]$MailboxType = "All",
    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

# --- Connect to Exchange Online ---
# Requires ExchangeOnlineManagement module
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    Write-Host "Install ExchangeOnlineManagement module first." -ForegroundColor Red
    exit 1
}

Connect-ExchangeOnline -ShowBanner:$false

# --- Get Mailboxes ---
Write-Host "Pulling mailboxes..." -ForegroundColor Cyan

$mailboxes = switch ($MailboxType) {
    "User"   { Get-Mailbox -RecipientTypeDetails UserMailbox -ResultSize Unlimited }
    "Shared" { Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited }
    default  { Get-Mailbox -ResultSize Unlimited }
}

Write-Host "Found $($mailboxes.Count) mailboxes" -ForegroundColor Green

# --- Build Report ---
$report = foreach ($mbx in $mailboxes) {
    $stats = Get-MailboxStatistics -Identity $mbx.Identity -ErrorAction SilentlyContinue

    # Get folder permissions on Calendar
    $calPerms = Get-MailboxFolderPermission -Identity "$($mbx.PrimarySmtpAddress):\Calendar" -ErrorAction SilentlyContinue |
        Where-Object { $_.User.DisplayName -notin @("Default", "Anonymous") }

    # Get delegates
    $delegates = Get-MailboxFolderPermission -Identity "$($mbx.PrimarySmtpAddress):\Calendar" -ErrorAction SilentlyContinue |
        Where-Object { $_.AccessRights -match "Editor|Owner" -and $_.User.DisplayName -notin @("Default", "Anonymous") }

    [PSCustomObject]@{
        DisplayName     = $mbx.DisplayName
        Email           = $mbx.PrimarySmtpAddress
        Type            = $mbx.RecipientTypeDetails
        TotalSize       = if ($stats) { $stats.TotalItemSize.ToString() } else { "N/A" }
        ItemCount       = if ($stats) { $stats.ItemCount } else { 0 }
        LastLogon       = if ($stats) { $stats.LastLogonTime } else { "Never" }
        CalendarDelegates = ($delegates | ForEach-Object { $_.User.DisplayName }) -join "; "
        CalendarPerms   = ($calPerms | ForEach-Object { "$($_.User.DisplayName):$($_.AccessRights)" }) -join "; "
        ForwardingTo    = $mbx.ForwardingSmtpAddress
        LitigationHold  = $mbx.LitigationHoldEnabled
    }
}

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "MailboxReport_$timestamp.xlsx"

$report | Export-Excel -Path $outFile `
    -WorksheetName "Mailboxes" `
    -AutoSize `
    -FreezeTopRow `
    -AutoFilter `
    -BoldTopRow

Write-Host "Report exported: $outFile" -ForegroundColor Green

Disconnect-ExchangeOnline -Confirm:$false
