<#
.SYNOPSIS
    Generates an Intune device report with encryption status and recovery keys.

.DESCRIPTION
    Queries Microsoft Graph API for managed devices, checks BitLocker encryption
    status, and retrieves recovery keys. Exports a formatted Excel report.

.EXAMPLE
    .\Get-DeviceReport.ps1
    Generates report for all managed Windows devices.

.EXAMPLE
    .\Get-DeviceReport.ps1 -InputFile "C:\devices.txt"
    Generates report for devices listed in the input file (one hostname per line).
#>

param(
    [string]$InputFile,
    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

# --- Auth ---
$headers = & "$PSScriptRoot\..\Graph-API\Get-MsToken.ps1" -Service Graph

# --- Helper: Paginated Graph query ---
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

# --- Get Devices ---
if ($InputFile) {
    $hostnames = Get-Content $InputFile | Where-Object { $_ -match '\S' }
    Write-Host "Checking $($hostnames.Count) devices from input file..." -ForegroundColor Cyan
    $devices = foreach ($name in $hostnames) {
        $encoded = [System.Uri]::EscapeDataString($name.Trim())
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$encoded'"
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
        if ($result.value) { $result.value[0] }
        else { [PSCustomObject]@{ deviceName = $name; complianceState = "NOT FOUND" } }
    }
}
else {
    Write-Host "Pulling all managed Windows devices..." -ForegroundColor Cyan
    $devices = Get-GraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'"
}

Write-Host "Found $($devices.Count) devices" -ForegroundColor Green

# --- Check Encryption + Recovery Keys ---
$report = foreach ($device in $devices) {
    $encryptionState = "Unknown"
    $recoveryKey = "N/A"

    if ($device.id -and $device.complianceState -ne "NOT FOUND") {
        # Check encryption
        try {
            $enc = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)?`$select=id,isEncrypted" -Headers $headers
            $encryptionState = if ($enc.isEncrypted) { "Encrypted" } else { "Not Encrypted" }
        }
        catch { $encryptionState = "Error" }

        # Get recovery key
        try {
            $azureDeviceId = $device.azureADDeviceId
            if ($azureDeviceId) {
                $keys = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$azureDeviceId'" -Headers $headers
                if ($keys.value) { $recoveryKey = "Available" }
            }
        }
        catch { $recoveryKey = "Error" }
    }

    [PSCustomObject]@{
        DeviceName      = $device.deviceName
        UserPrincipal   = $device.userPrincipalName
        OS              = $device.operatingSystem
        OSVersion       = $device.osVersion
        Compliance      = $device.complianceState
        Encryption      = $encryptionState
        RecoveryKey     = $recoveryKey
        LastSync        = $device.lastSyncDateTime
        EnrollmentDate  = $device.enrolledDateTime
        Manufacturer    = $device.manufacturer
        Model           = $device.model
        SerialNumber    = $device.serialNumber
    }
}

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "DeviceReport_$timestamp.xlsx"

$report | Export-Excel -Path $outFile `
    -WorksheetName "Devices" `
    -AutoSize `
    -FreezeTopRow `
    -AutoFilter `
    -BoldTopRow `
    -ConditionalText $(
        New-ConditionalText -Text "Not Encrypted" -BackgroundColor "#FFCCCC" -ConditionalTextColor "#CC0000"
        New-ConditionalText -Text "Encrypted" -BackgroundColor "#CCFFCC" -ConditionalTextColor "#006600"
        New-ConditionalText -Text "NOT FOUND" -BackgroundColor "#FFFFCC" -ConditionalTextColor "#CC6600"
    )

Write-Host "Report exported: $outFile" -ForegroundColor Green
