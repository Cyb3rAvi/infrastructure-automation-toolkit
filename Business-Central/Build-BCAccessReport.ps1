<#
.SYNOPSIS
    Generates a Business Central user access review report.

.DESCRIPTION
    Joins BC Users, Permission Sets, and User Permission Sets data to create
    a consolidated access report. Flags elevated permissions and service accounts.
    Exports formatted Excel with review columns for compliance attestation.

.PARAMETER UsersFile
    Path to the BC Users export (xlsx or csv).

.PARAMETER PermSetsFile
    Path to the Permission Sets export (xlsx or csv).

.PARAMETER UserPermSetsFile
    Path to the User Permission Sets export. Use CSV for large files (500K+ rows).

.NOTES
    For large User Permission Sets files, always use CSV format.
    The xlsx version can hang ImportExcel for 10+ minutes on 500K+ rows.

.EXAMPLE
    .\Build-BCAccessReport.ps1 -UsersFile "Users.xlsx" -PermSetsFile "PermissionSets.xlsx" -UserPermSetsFile "UserPermSets.csv"
#>

param(
    [Parameter(Mandatory)]
    [string]$UsersFile,

    [Parameter(Mandatory)]
    [string]$PermSetsFile,

    [Parameter(Mandatory)]
    [string]$UserPermSetsFile,

    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

# --- Elevated Permission Patterns ---
$elevatedPatterns = @(
    "SUPER", "SECURITY", "D365 FULL", "D365 BUS FULL", "ADMIN",
    "ALLOW-BANK-EDIT", "ALLOW-CHECKSIGN-EDIT", "ALLOW-JOURNAL-POST",
    "GL-SETUP", "AP-SETUP", "AR-SETUP", "FA-SETUP"
)

# --- Load Data ---
Write-Host "Loading Users..." -ForegroundColor Cyan
$users = if ($UsersFile -match '\.csv$') {
    Import-Csv $UsersFile
} else {
    Import-Excel $UsersFile
}
Write-Host "  $($users.Count) users loaded" -ForegroundColor Green

Write-Host "Loading Permission Sets..." -ForegroundColor Cyan
$permSets = if ($PermSetsFile -match '\.csv$') {
    Import-Csv $PermSetsFile
} else {
    Import-Excel $PermSetsFile
}
Write-Host "  $($permSets.Count) permission sets loaded" -ForegroundColor Green

Write-Host "Loading User Permission Sets (this may take a moment)..." -ForegroundColor Cyan
$userPermSets = if ($UserPermSetsFile -match '\.csv$') {
    Import-Csv $UserPermSetsFile
} else {
    Write-Host "  WARNING: Large xlsx files are slow. Use CSV for better performance." -ForegroundColor Yellow
    Import-Excel $UserPermSetsFile
}
Write-Host "  $($userPermSets.Count) user permission sets loaded" -ForegroundColor Green

# --- Build Lookup ---
Write-Host "Building permission lookup..." -ForegroundColor Cyan

$userPermLookup = @{}
foreach ($up in $userPermSets) {
    $userId = $up.'User Security ID'
    if (-not $userId) { $userId = $up.UserSecurityID }
    if (-not $userPermLookup[$userId]) { $userPermLookup[$userId] = @() }
    $roleName = $up.'Role ID'
    if (-not $roleName) { $roleName = $up.RoleID }
    $userPermLookup[$userId] += $roleName
}

# --- Build Report ---
Write-Host "Building report..." -ForegroundColor Cyan

$report = foreach ($user in $users) {
    $secId = $user.'User Security ID'
    if (-not $secId) { $secId = $user.UserSecurityID }

    $perms = $userPermLookup[$secId]
    $permList = if ($perms) { ($perms | Sort-Object -Unique) -join ", " } else { "None" }
    $permCount = if ($perms) { ($perms | Sort-Object -Unique).Count } else { 0 }

    # Check for elevated access
    $elevated = @()
    if ($perms) {
        foreach ($pattern in $elevatedPatterns) {
            $matches = $perms | Where-Object { $_ -match $pattern }
            $elevated += $matches
        }
    }
    $hasElevated = $elevated.Count -gt 0
    $elevatedList = ($elevated | Sort-Object -Unique) -join ", "

    # Service/shared account detection
    $userName = $user.'User Name'
    if (-not $userName) { $userName = $user.UserName }
    $isServiceAccount = $userName -match "svc\.|service|api|system|shared|generic"

    $state = $user.State
    if (-not $state) { $state = $user.Status }
    $isEnabled = $state -match "Enabled|Active|Yes"

    [PSCustomObject]@{
        UserName          = $userName
        FullName          = $user.'Full Name'
        Email             = $user.'Contact Email'
        State             = $state
        IsEnabled         = $isEnabled
        PermissionCount   = $permCount
        HasElevatedAccess = $hasElevated
        ElevatedPerms     = $elevatedList
        IsServiceAccount  = $isServiceAccount
        AllPermissions    = $permList
        # Review columns
        AccessAppropriate = ""
        ActionRequired    = ""
        Comments          = ""
    }
}

# --- Summary ---
$enabled = ($report | Where-Object { $_.IsEnabled }).Count
$disabled = ($report | Where-Object { -not $_.IsEnabled }).Count
$elevated = ($report | Where-Object { $_.HasElevatedAccess }).Count
$svcAccounts = ($report | Where-Object { $_.IsServiceAccount }).Count

Write-Host "`nSummary:" -ForegroundColor Yellow
Write-Host "  Total users:      $($report.Count)"
Write-Host "  Enabled:          $enabled" -ForegroundColor Green
Write-Host "  Disabled:         $disabled" -ForegroundColor Gray
Write-Host "  Elevated access:  $elevated" -ForegroundColor Red
Write-Host "  Service accounts: $svcAccounts" -ForegroundColor Yellow

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "BC_AccessReport_$timestamp.xlsx"

$report | Sort-Object -Property @{Expression = "HasElevatedAccess"; Descending = $true}, UserName |
    Export-Excel -Path $outFile `
        -WorksheetName "BC Access Review" `
        -AutoSize -FreezeTopRow -AutoFilter -BoldTopRow `
        -ConditionalText $(
            New-ConditionalText -Text "True" -BackgroundColor "#FFCCCC" -ConditionalTextColor "#CC0000"
            New-ConditionalText -Text "Disabled" -BackgroundColor "#E0E0E0" -ConditionalTextColor "#666666"
        )

Write-Host "Report exported: $outFile" -ForegroundColor Green
