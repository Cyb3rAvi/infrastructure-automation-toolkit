<#
.SYNOPSIS
    Generates a full hybrid AD device inventory from Entra ID and Intune.

.DESCRIPTION
    Pulls Windows device records from both Entra ID and Intune, merges them
    into a single inventory with ownership, enrollment type, OS version,
    compliance state, and last activity timestamps.

.EXAMPLE
    .\Get-DeviceInventory.ps1
    Exports full device inventory to Excel.
#>

param(
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

# --- Pull Data ---
Write-Host "Pulling Entra ID devices..." -ForegroundColor Cyan
$entraDevices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=operatingSystem eq 'Windows'&`$select=id,displayName,operatingSystem,operatingSystemVersion,approximateLastSignInDateTime,trustType,accountEnabled,deviceId"

Write-Host "Pulling Intune devices..." -ForegroundColor Cyan
$intuneDevices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'"

Write-Host "Entra: $($entraDevices.Count) | Intune: $($intuneDevices.Count)" -ForegroundColor Green

# --- Build Intune Lookup ---
$intuneLookup = @{}
foreach ($device in $intuneDevices) {
    $intuneLookup[$device.deviceName.ToLower()] = $device
}

# --- Merge ---
Write-Host "Building inventory..." -ForegroundColor Cyan

$inventory = foreach ($entra in $entraDevices) {
    $intune = $intuneLookup[$entra.displayName.ToLower()]

    [PSCustomObject]@{
        DeviceName       = $entra.displayName
        EntraEnabled     = $entra.accountEnabled
        TrustType        = $entra.trustType
        EntraLastSignIn  = $entra.approximateLastSignInDateTime
        InIntune         = [bool]$intune
        IntuneCompliance = if ($intune) { $intune.complianceState } else { "N/A" }
        IntuneLastSync   = if ($intune) { $intune.lastSyncDateTime } else { "N/A" }
        UserPrincipal    = if ($intune) { $intune.userPrincipalName } else { "N/A" }
        Ownership        = if ($intune) { $intune.managedDeviceOwnerType } else { "N/A" }
        Encrypted        = if ($intune) { $intune.isEncrypted } else { "N/A" }
        OS               = if ($intune) { $intune.operatingSystem } else { $entra.operatingSystem }
        OSVersion        = if ($intune) { $intune.osVersion } else { $entra.operatingSystemVersion }
        Manufacturer     = if ($intune) { $intune.manufacturer } else { "N/A" }
        Model            = if ($intune) { $intune.model } else { "N/A" }
        SerialNumber     = if ($intune) { $intune.serialNumber } else { "N/A" }
        EnrolledDate     = if ($intune) { $intune.enrolledDateTime } else { "N/A" }
        EntraDeviceId    = $entra.deviceId
    }
}

# --- Summary ---
$inBoth = ($inventory | Where-Object { $_.InIntune }).Count
$entraOnly = ($inventory | Where-Object { -not $_.InIntune }).Count

Write-Host "`nInventory Summary:" -ForegroundColor Yellow
Write-Host "  Total devices:  $($inventory.Count)"
Write-Host "  In both:        $inBoth" -ForegroundColor Green
Write-Host "  Entra only:     $entraOnly" -ForegroundColor Yellow

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "DeviceInventory_$timestamp.xlsx"

$inventory | Sort-Object DeviceName |
    Export-Excel -Path $outFile `
        -WorksheetName "Inventory" `
        -AutoSize -FreezeTopRow -AutoFilter -BoldTopRow

Write-Host "Report exported: $outFile" -ForegroundColor Green
