<#
    Detect-HpLoopUpdatesVisible.ps1   (Intune remediation - DETECTION half of "Hide HP Driver Update Loop")
    Exit 1 = at least one HP loop update is still VISIBLE (pending, not hidden) -> remediation runs.
    Exit 0 = none visible (clean, or already hidden).
    Read-only. Runs as SYSTEM, 64-bit, no signature check.

    Scope - ONLY the known loop driver items (not every HP update):
        Hewlett-Packard - USB - <date> - <ver>          (e.g. 1.0.0.237, 48.2.4483.1963)
        HP Inc. - WSD Printer - HP Printer (BIDI)
#>
$ErrorActionPreference = 'SilentlyContinue'
$rx = '^(Hewlett-Packard - USB - |HP Inc\. - WSD Printer - HP Printer \(BIDI\))'

$job = Start-Job -ScriptBlock {
    $r = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver'")
    foreach ($u in $r.Updates) { [pscustomobject]@{ Title = $u.Title; Hidden = [bool]$u.IsHidden } }
}
if (-not (Wait-Job $job -Timeout 150)) {
    Stop-Job $job; Remove-Job $job -Force
    Write-Output 'Unknown: WU search timed out'
    exit 0   # never trigger remediation on a timeout
}
$all = @(Receive-Job $job); Remove-Job $job -Force

$loop    = @($all | Where-Object { $_.Title -match $rx })
$visible = @($loop | Where-Object { -not $_.Hidden })
$hidden  = @($loop | Where-Object { $_.Hidden })

if ($visible.Count -gt 0) {
    Write-Output ("NonCompliant: visible={0} hidden={1} | {2}" -f $visible.Count, $hidden.Count, ((@($visible | ForEach-Object { $_.Title.Substring(0,[Math]::Min(60,$_.Title.Length)) }) -join ' ; ')))
    exit 1
}
Write-Output ("Compliant: visible=0 hidden={0}" -f $hidden.Count)
exit 0
