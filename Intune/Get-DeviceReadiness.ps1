<#
.SYNOPSIS
    Assesses device readiness for SecureBoot, VT-x, UEFI, and BitLocker.

.DESCRIPTION
    Intune remediation detection script. Checks firmware, disk partition,
    virtualization, and encryption status. Categorizes devices into
    remediation buckets for automated or manual intervention.

    Buckets:
      A = All good (no action needed)
      B = Safe to remediate remotely (GPT + UEFI + supported manufacturer)
      C = MBR/Legacy BIOS (requires manual intervention)
      D = Unsupported manufacturer (requires manual intervention)

.NOTES
    Deploy via Intune Remediations (Proactive Remediations).
    Detection script only — does not make changes.
#>

# --- Gather Device Info ---
$computerInfo = Get-ComputerInfo -Property @(
    "BiosFirmwareType",
    "CsManufacturer",
    "CsModel",
    "OsName"
)

$secureBoot = try { Confirm-SecureBootUEFI } catch { $false }
$vtx = (Get-CimInstance -ClassName Win32_Processor).VirtualizationFirmwareEnabled
$hypervisor = (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
$vbs = (Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue).VirtualizationBasedSecurityStatus

# Disk info
$osDrive = (Get-CimInstance -ClassName Win32_OperatingSystem).SystemDrive
$diskNumber = (Get-Partition -DriveLetter $osDrive[0]).DiskNumber
$diskStyle = (Get-Disk -Number $diskNumber).PartitionStyle

# BitLocker
$bitlocker = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction SilentlyContinue
$blStatus = if ($bitlocker) { $bitlocker.ProtectionStatus.ToString() } else { "Unknown" }

# --- Categorize ---
$firmware = $computerInfo.BiosFirmwareType.ToString()
$manufacturer = $computerInfo.CsManufacturer
$isGPT = $diskStyle -eq "GPT"
$isUEFI = $firmware -eq "Uefi"
$isLenovo = $manufacturer -match "Lenovo"

$safeToRemediate = $isGPT -and $isUEFI -and $isLenovo

if ($secureBoot -and $vtx -and $blStatus -eq "On") {
    $bucket = "A"  # All good
}
elseif ($safeToRemediate) {
    $bucket = "B"  # Safe for remote remediation
}
elseif (-not $isGPT -or -not $isUEFI) {
    $bucket = "C"  # MBR/Legacy — manual
}
else {
    $bucket = "D"  # Unsupported manufacturer — manual
}

# --- Output ---
$result = [PSCustomObject]@{
    DeviceName       = $env:COMPUTERNAME
    SecureBoot       = $secureBoot
    VTx              = $vtx
    Hypervisor       = $hypervisor
    VBS              = $vbs
    Firmware         = $firmware
    DiskStyle        = $diskStyle
    BitLocker        = $blStatus
    Manufacturer     = $manufacturer
    Model            = $computerInfo.CsModel
    Bucket           = $bucket
    SafeToRemediate  = $safeToRemediate
}

$result | ConvertTo-Json -Compress | Write-Output

# Exit code for Intune: 0 = compliant, 1 = non-compliant
if ($bucket -eq "A") { exit 0 } else { exit 1 }
