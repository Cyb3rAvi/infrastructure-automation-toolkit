<#
.SYNOPSIS
    Intune remediation DETECTION script: checks the Edge and Chrome homepage policy.

.DESCRIPTION
    Pair for Set-BrowserHomepage.ps1 (the remediation). Reads the same HKLM policy
    values and exits 1 if any is missing or wrong, so Intune runs the remediation.
    Exits 0 when both browsers already match. Read-only: changes nothing.

.NOTES
    Keep $homepageUrl and $newTabUrl identical to the ones in Set-BrowserHomepage.ps1.
    Intune settings: run as SYSTEM, 64-bit PowerShell, signature check off.
#>

# --- Configuration (must match Set-BrowserHomepage.ps1) ---
$homepageUrl = "https://YOUR_HOMEPAGE_URL"
$newTabUrl   = "https://YOUR_NEWTAB_URL"

$expected = @{
    RestoreOnStartup     = 4
    HomepageLocation     = $homepageUrl
    HomepageIsNewTabPage = 0
    NewTabPageLocation   = $newTabUrl
    ShowHomeButton       = 1
}

$browsers = @{
    Edge   = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    Chrome = "HKLM:\SOFTWARE\Policies\Google\Chrome"
}

$problems = @()

foreach ($name in $browsers.Keys) {
    $path = $browsers[$name]
    $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue

    foreach ($key in $expected.Keys) {
        if ($null -eq $props -or $props.$key -ne $expected[$key]) {
            $problems += "$name/$key"
        }
    }

    $startup = Get-ItemProperty -Path "$path\RestoreOnStartupURLs" -ErrorAction SilentlyContinue
    if ($null -eq $startup -or $startup."1" -ne $homepageUrl) {
        $problems += "$name/RestoreOnStartupURLs/1"
    }
}

if ($problems.Count -gt 0) {
    Write-Output ("NonCompliant: " + ($problems -join ", "))
    exit 1
}

Write-Output "Compliant: Edge and Chrome homepage policy matches"
exit 0
