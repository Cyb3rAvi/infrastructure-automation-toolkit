<#
.SYNOPSIS
    Generates a phased BitLocker encryption compliance report.

.DESCRIPTION
    Takes a list of device hostnames (grouped by deployment phase) and checks
    encryption status, recovery key availability, and compliance state via
    Microsoft Graph API. Exports a formatted Excel report with conditional formatting.

.PARAMETER InputFile
    Path to a text file with one hostname per line.

.PARAMETER Phase
    Label for the deployment phase (e.g., "Phase1", "Phase2").

.EXAMPLE
    .\Get-BitLockerReport.ps1 -InputFile "C:\phase1-devices.txt" -Phase "Phase1"
#>

param(
    [Parameter(Mandatory)]
    [string]$InputFile,

    [string]$Phase = "AllDevices",
    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

# --- Auth ---
$headers = & "$PSScriptRoot\..\Graph-API\Get-MsToken.ps1" -Service Graph

# --- Load Devices ---
if (-not (Test-Path $InputFile)) {
    Write-Host "Input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

$hostnames = Get-Content $InputFile | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }
Write-Host "Checking $($hostnames.Count) devices for $Phase..." -ForegroundColor Cyan

# --- Check Each Device ---
$report = foreach ($name in $hostnames) {
    $encoded = [System.Uri]::EscapeDataString($name)
    $device = $null
    $encryptionState = "Unknown"
    $recoveryKey = "N/A"
    $compliance = "NOT FOUND"

    try {
        $result = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$encoded'" -Headers $headers
        if ($result.value.Count -gt 0) {
            $device = $result.value[0]
            $compliance = $device.complianceState

            # Encryption status
            try {
                $enc = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)?`$select=id,isEncrypted" -Headers $headers
                $encryptionState = if ($enc.isEncrypted) { "Encrypted" } else { "Not Encrypted" }
            }
            catch { $encryptionState = "Error" }

            # Recovery key
            try {
                $azureDeviceId = $device.azureADDeviceId
                if ($azureDeviceId) {
                    $keys = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$azureDeviceId'" -Headers $headers
                    $recoveryKey = if ($keys.value.Count -gt 0) { "Available" } else { "Missing" }
                }
            }
            catch { $recoveryKey = "Error" }
        }
    }
    catch { $compliance = "API Error" }

    [PSCustomObject]@{
        Phase          = $Phase
        DeviceName     = $name
        UserPrincipal  = $device.userPrincipalName
        Encryption     = $encryptionState
        RecoveryKey    = $recoveryKey
        Compliance     = $compliance
        LastSync       = $device.lastSyncDateTime
        OS             = $device.osVersion
        Manufacturer   = $device.manufacturer
        Model          = $device.model
        SerialNumber   = $device.serialNumber
    }
}

# --- Summary ---
$encrypted = ($report | Where-Object { $_.Encryption -eq "Encrypted" }).Count
$notEncrypted = ($report | Where-Object { $_.Encryption -eq "Not Encrypted" }).Count
$notFound = ($report | Where-Object { $_.Compliance -eq "NOT FOUND" }).Count

Write-Host "`n$Phase Summary:" -ForegroundColor Yellow
Write-Host "  Encrypted:     $encrypted" -ForegroundColor Green
Write-Host "  Not Encrypted: $notEncrypted" -ForegroundColor Red
Write-Host "  Not Found:     $notFound" -ForegroundColor Yellow

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "BitLocker_${Phase}_$timestamp.xlsx"

$report | Export-Excel -Path $outFile `
    -WorksheetName $Phase `
    -AutoSize -FreezeTopRow -AutoFilter -BoldTopRow `
    -ConditionalText $(
        New-ConditionalText -Text "Not Encrypted" -BackgroundColor "#FFCCCC" -ConditionalTextColor "#CC0000"
        New-ConditionalText -Text "Encrypted" -BackgroundColor "#CCFFCC" -ConditionalTextColor "#006600"
        New-ConditionalText -Text "NOT FOUND" -BackgroundColor "#FFFFCC" -ConditionalTextColor "#CC6600"
        New-ConditionalText -Text "Missing" -BackgroundColor "#FFE0CC" -ConditionalTextColor "#CC3300"
    )

Write-Host "Report exported: $outFile" -ForegroundColor Green
