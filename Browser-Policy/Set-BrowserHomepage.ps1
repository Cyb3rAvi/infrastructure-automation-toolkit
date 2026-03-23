<#
.SYNOPSIS
    Intune remediation script to enforce browser homepage via HKLM registry.

.DESCRIPTION
    Sets Edge and Chrome homepage policies using HKLM registry keys,
    which override any user-level (HKCU) settings. Designed to run as
    an Intune Proactive Remediation (detection + remediation pair).

    This is the REMEDIATION script. Deploy alongside the detection script.

.NOTES
    - HKLM keys require SYSTEM or admin context (Intune runs as SYSTEM)
    - HKLM overrides HKCU — users cannot change the homepage
    - Applies to both Microsoft Edge and Google Chrome
#>

# --- Configuration ---
$homepageUrl = "https://YOUR_HOMEPAGE_URL"
$newTabUrl   = "https://YOUR_NEWTAB_URL"

# --- Edge (Chromium) Registry Paths ---
$edgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
$edgeStartup = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\RestoreOnStartupURLs"

# --- Chrome Registry Paths ---
$chromePath = "HKLM:\SOFTWARE\Policies\Google\Chrome"
$chromeStartup = "HKLM:\SOFTWARE\Policies\Google\Chrome\RestoreOnStartupURLs"

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = "DWord"
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

# --- Apply Edge Policy ---
Write-Host "Setting Edge homepage policy..." -ForegroundColor Cyan

# RestoreOnStartup: 4 = Open specific URLs
Set-RegistryValue -Path $edgePath -Name "RestoreOnStartup" -Value 4

# Homepage URL
Set-RegistryValue -Path $edgePath -Name "HomepageLocation" -Value $homepageUrl -Type "String"
Set-RegistryValue -Path $edgePath -Name "HomepageIsNewTabPage" -Value 0

# New tab page
Set-RegistryValue -Path $edgePath -Name "NewTabPageLocation" -Value $newTabUrl -Type "String"

# Startup URLs
Set-RegistryValue -Path $edgeStartup -Name "1" -Value $homepageUrl -Type "String"

# Show home button
Set-RegistryValue -Path $edgePath -Name "ShowHomeButton" -Value 1

Write-Host "  Edge: Done" -ForegroundColor Green

# --- Apply Chrome Policy ---
Write-Host "Setting Chrome homepage policy..." -ForegroundColor Cyan

Set-RegistryValue -Path $chromePath -Name "RestoreOnStartup" -Value 4
Set-RegistryValue -Path $chromePath -Name "HomepageLocation" -Value $homepageUrl -Type "String"
Set-RegistryValue -Path $chromePath -Name "HomepageIsNewTabPage" -Value 0
Set-RegistryValue -Path $chromePath -Name "NewTabPageLocation" -Value $newTabUrl -Type "String"
Set-RegistryValue -Path $chromeStartup -Name "1" -Value $homepageUrl -Type "String"
Set-RegistryValue -Path $chromePath -Name "ShowHomeButton" -Value 1

Write-Host "  Chrome: Done" -ForegroundColor Green

Write-Host "`nBrowser homepage policy applied successfully." -ForegroundColor Green
Write-Host "Homepage: $homepageUrl" -ForegroundColor Gray
Write-Host "Note: HKLM policy overrides any user-level settings." -ForegroundColor Yellow

exit 0
