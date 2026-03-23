<#
.SYNOPSIS
    Identifies and removes stale devices from Entra ID and Intune.

.DESCRIPTION
    Queries Microsoft Graph for devices not synced within a specified number of days.
    Displays stale devices for review and optionally removes them with confirmation.

.PARAMETER StaleDays
    Number of days since last activity to consider a device stale. Default: 90

.PARAMETER DryRun
    If specified, only lists stale devices without removing them.

.EXAMPLE
    .\Remove-StaleDevices.ps1 -StaleDays 90 -DryRun
    Lists all devices inactive for 90+ days without deleting.

.EXAMPLE
    .\Remove-StaleDevices.ps1 -StaleDays 60
    Finds and prompts to remove devices inactive for 60+ days.
#>

param(
    [int]$StaleDays = 90,
    [switch]$DryRun
)

# --- Auth ---
$headers = & "$PSScriptRoot\..\Graph-API\Get-MsToken.ps1" -Service Graph

# --- Helper ---
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

# --- Get Stale Devices ---
$cutoffDate = (Get-Date).AddDays(-$StaleDays).ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Finding devices inactive since $cutoffDate..." -ForegroundColor Cyan

# Entra ID devices
$entraDevices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=operatingSystem eq 'Windows' and approximateLastSignInDateTime le $cutoffDate&`$select=id,displayName,approximateLastSignInDateTime,trustType,operatingSystem"

# Intune managed devices
$intuneDevices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,deviceName,lastSyncDateTime,managedDeviceOwnerType,enrolledDateTime"

$staleIntune = $intuneDevices | Where-Object {
    $_.lastSyncDateTime -and [datetime]$_.lastSyncDateTime -lt (Get-Date).AddDays(-$StaleDays)
}

Write-Host "`nStale Entra devices (${StaleDays}+ days): $($entraDevices.Count)" -ForegroundColor Yellow
Write-Host "Stale Intune devices (${StaleDays}+ days): $($staleIntune.Count)" -ForegroundColor Yellow

# --- Display ---
$report = @()

foreach ($device in $entraDevices) {
    $report += [PSCustomObject]@{
        Source    = "Entra ID"
        Name      = $device.displayName
        LastSeen  = $device.approximateLastSignInDateTime
        TrustType = $device.trustType
        Id        = $device.id
    }
}

foreach ($device in $staleIntune) {
    $report += [PSCustomObject]@{
        Source    = "Intune"
        Name      = $device.deviceName
        LastSeen  = $device.lastSyncDateTime
        TrustType = $device.managedDeviceOwnerType
        Id        = $device.id
    }
}

$report | Sort-Object LastSeen | Format-Table -AutoSize

if ($DryRun) {
    Write-Host "`nDry run — no devices removed." -ForegroundColor Green
    return
}

# --- Remove with confirmation ---
$confirm = Read-Host "`nRemove $($report.Count) stale devices? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    return
}

$removed = 0
$errors = 0

foreach ($device in $report) {
    try {
        if ($device.Source -eq "Entra ID") {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices/$($device.Id)" -Headers $headers -Method DELETE
        }
        else {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.Id)" -Headers $headers -Method DELETE
        }
        Write-Host "Removed: $($device.Name) ($($device.Source))" -ForegroundColor Green
        $removed++
    }
    catch {
        Write-Host "Failed: $($device.Name) — $($_.Exception.Message)" -ForegroundColor Red
        $errors++
    }
}

Write-Host "`nDone. Removed: $removed | Errors: $errors" -ForegroundColor Cyan
