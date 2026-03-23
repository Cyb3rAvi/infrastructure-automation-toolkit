<#
.SYNOPSIS
    Compares Entra ID and Intune device records to identify stale and orphaned entries.

.DESCRIPTION
    Pulls device records from both Entra ID and Intune, cross-references them,
    and flags discrepancies: devices in Entra but not Intune, stale sign-ins,
    duplicate records (AzureAD vs ServerAD trust types), and Workplace-joined
    devices from RDS sessions.

.PARAMETER StaleDays
    Days since last activity to flag as stale. Default: 30

.EXAMPLE
    .\Get-StaleDevices.ps1 -StaleDays 60
    Flags devices inactive for 60+ days.
#>

param(
    [int]$StaleDays = 30,
    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

# --- Auth ---
$headers = & "$PSScriptRoot\..\Graph-API\Get-MsToken.ps1" -Service Graph

function Get-GraphAllPages {
    param([string]$Uri)
    $results = @()
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-RestMethod -Uri $nextUri -Headers $headers -Method GET
        $results += $response.value
        $nextUri = $response.'@odata.nextLink'
    }
    return $results
}

# --- Pull Entra Devices ---
Write-Host "Pulling Entra ID devices..." -ForegroundColor Cyan
$entraDevices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,operatingSystem,approximateLastSignInDateTime,trustType,accountEnabled,registeredOwners&`$filter=operatingSystem eq 'Windows'"

Write-Host "Entra ID: $($entraDevices.Count) Windows devices" -ForegroundColor Green

# --- Pull Intune Devices ---
Write-Host "Pulling Intune devices..." -ForegroundColor Cyan
$intuneDevices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,deviceName,lastSyncDateTime,enrolledDateTime,userPrincipalName,managedDeviceOwnerType"

Write-Host "Intune: $($intuneDevices.Count) Windows devices" -ForegroundColor Green

# --- Cross-Reference ---
$cutoff = (Get-Date).AddDays(-$StaleDays)
$intuneNames = $intuneDevices | ForEach-Object { $_.deviceName.ToLower() }

$report = foreach ($device in $entraDevices) {
    $lastSignIn = if ($device.approximateLastSignInDateTime) { [datetime]$device.approximateLastSignInDateTime } else { $null }
    $isStale = $lastSignIn -and ($lastSignIn -lt $cutoff)
    $inIntune = $device.displayName.ToLower() -in $intuneNames
    $isWorkplace = $device.trustType -eq "Workplace"

    # Flag duplicates: same name with different trust types
    $duplicateCount = ($entraDevices | Where-Object { $_.displayName -eq $device.displayName }).Count

    # Determine action recommendation
    $recommendation = "None"
    if ($isStale -and -not $inIntune) { $recommendation = "Safe to Remove" }
    elseif ($isStale -and $isWorkplace) { $recommendation = "RDS Artifact - Remove" }
    elseif ($duplicateCount -gt 1 -and $device.trustType -eq "AzureAd" -and -not $device.accountEnabled) {
        $recommendation = "Duplicate - Review"
    }
    elseif ($isStale) { $recommendation = "Stale - Review" }

    [PSCustomObject]@{
        DeviceName     = $device.displayName
        TrustType      = $device.trustType
        Enabled        = $device.accountEnabled
        LastSignIn     = $lastSignIn
        IsStale        = $isStale
        InIntune       = $inIntune
        Duplicates     = $duplicateCount
        Recommendation = $recommendation
        EntraId        = $device.id
    }
}

# --- Summary ---
$staleCount = ($report | Where-Object { $_.IsStale }).Count
$orphanCount = ($report | Where-Object { -not $_.InIntune }).Count
$actionable = ($report | Where-Object { $_.Recommendation -ne "None" }).Count

Write-Host "`nSummary:" -ForegroundColor Yellow
Write-Host "  Total Entra records: $($entraDevices.Count)"
Write-Host "  Total Intune records: $($intuneDevices.Count)"
Write-Host "  Stale ($StaleDays+ days): $staleCount" -ForegroundColor Red
Write-Host "  Not in Intune: $orphanCount" -ForegroundColor Yellow
Write-Host "  Actionable: $actionable" -ForegroundColor Cyan

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "StaleDevices_$timestamp.xlsx"

$report | Sort-Object Recommendation, LastSignIn |
    Export-Excel -Path $outFile `
        -WorksheetName "Stale Devices" `
        -AutoSize -FreezeTopRow -AutoFilter -BoldTopRow `
        -ConditionalText $(
            New-ConditionalText -Text "Safe to Remove" -BackgroundColor "#FFCCCC" -ConditionalTextColor "#CC0000"
            New-ConditionalText -Text "RDS Artifact" -BackgroundColor "#FFE0CC" -ConditionalTextColor "#CC3300"
            New-ConditionalText -Text "Duplicate" -BackgroundColor "#FFFFCC" -ConditionalTextColor "#CC6600"
        )

Write-Host "Report exported: $outFile" -ForegroundColor Green
