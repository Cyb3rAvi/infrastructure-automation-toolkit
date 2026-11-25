<#
    Remediate-HpLoopUpdatesHide.ps1   (Intune remediation - REMEDIATION half of "Hide HP Driver Update Loop")
    Hides the known HP loop driver updates in Windows Update (same as the "Show or hide updates"
    tool: IUpdate.IsHidden = $true). Does NOT install, uninstall or change any driver, policy or registry.
    Reversible: set IsHidden = $false on the same update (or use Microsoft's "Show or hide updates" tool).
    Re-verifies after hiding; exit 0 only if no loop update is left visible.
    Runs as SYSTEM, 64-bit, no signature check.
#>
$ErrorActionPreference = 'Stop'
$rx = '^(Hewlett-Packard - USB - |HP Inc\. - WSD Printer - HP Printer \(BIDI\))'

try {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $r = $searcher.Search("IsInstalled=0 and Type='Driver'")
    $done = 0; $failed = 0
    foreach ($u in $r.Updates) {
        if ($u.Title -match $rx -and -not $u.IsHidden) {
            try { $u.IsHidden = $true; $done++ } catch { $failed++ }
        }
    }
    # verify
    $r2 = $searcher.Search("IsInstalled=0 and Type='Driver'")
    $left = @($r2.Updates | Where-Object { $_.Title -match $rx -and -not $_.IsHidden }).Count
    $nowHidden = @($r2.Updates | Where-Object { $_.Title -match $rx -and $_.IsHidden }).Count
    Write-Output ("Hidden this run={0} failed={1} | verify: visible={2} hidden={3}" -f $done, $failed, $left, $nowHidden)
    if ($left -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Output ("ERROR: " + $_.Exception.Message)
    exit 1
}
