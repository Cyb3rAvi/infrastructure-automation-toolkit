<#
    Detect-HpDriverUpdateLoop.ps1
    ------------------------------------------------------------------
    Intune Remediation - DETECTION ONLY (no remediation script attached).
    Survey of the Windows Update HP driver loop ("Hewlett-Packard - USB - 4/8/2019 - 1.0.0.237",
    error 0x80246007, offered again every cycle). Changes NOTHING on the device: no hide, no install,
    no registry/policy writes. Only reads WU history, runs one WU "pending" search (the same scan
    Windows already does daily), reads the driver store, PnP devices and policy keys.

    Intune settings:
        Run using logged-on credentials : No  (SYSTEM)
        Enforce signature check         : No
        Run in 64-bit PowerShell        : Yes

    Output: ONE line, key=value pairs separated by '|' (easy to parse into a CSV).
    Verdict is always the first field.

    Verdicts
        Looping       - HP update still visible/pending AND >=3 distinct failure days in last 60d
        Pending       - HP update visible/pending, fewer than 3 failure days
        Hidden        - HP update(s) pending but ALL hidden (someone already hid them)
        PastFailures  - HP failures in the last 60d, nothing pending now
        Clean         - no HP update activity failing or pending
        Unknown       - could not read WU history

    Exit codes (portal grouping only):
        exit 1 = Looping or Pending (HP update visible, i.e. user-facing)
        exit 0 = everything else

    Field notes
        HpFailDays / HpOkDays  distinct DAYS (WU logs each attempt twice per day, so raw entries double-count)
        Dates are UTC (WU history stores UTC)
        HpUsbPresent           HP USB devices connected right now (VID_03F0); 0 = no HP printer plugged in
        HpUsbInstalled         HP USB driver packages already in the driver store (a NEWER one than the
                               offered 1.0.0.237 is the suspected reason the offer never sticks)
        ExclDrv                ExcludeWUDriversInQualityUpdate policy (1 = WU driver offers blocked)
        DrvEnrolled            Intune Driver Update management enrolment (1 = enrolled)
        OtherFail*             failures of NON-HP updates in last 60d (top offender) - the "is it only HP?" check
#>

$ErrorActionPreference = 'SilentlyContinue'
$days = 60
$cut  = (Get-Date).ToUniversalTime().AddDays(-$days)
$hpRx = '^(Hewlett-Packard|HP\b)'

function Short-Title([string]$t) {
    if ($t -match '^Hewlett-Packard - (\S+) - .* - ([\d\.]+)\.?\s*$') { return ('{0} {1}' -f $Matches[1], $Matches[2]) }
    if ($t.Length -gt 45) { return $t.Substring(0,45) }
    return $t
}
function Clean([string]$s) { if ($null -eq $s) { return '' }; return (($s -replace '[\|\r\n=]', ' ').Trim()) }

# --- 1. Device identity ---------------------------------------------
$cs   = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$os   = Get-CimInstance -ClassName Win32_OperatingSystem

# --- 2. WU history (last 60d) ----------------------------------------
$histOk = $true
$hist = @()
try {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $n = $searcher.GetTotalHistoryCount()
    if ($n -gt 0) {
        $hist = @($searcher.QueryHistory(0, [Math]::Min($n, 2000)) | Where-Object { $_.Title -and $_.Date -gt $cut })
    }
} catch { $histOk = $false }

$hp    = @($hist | Where-Object { $_.Title -match $hpRx })
$hpF   = @($hp   | Where-Object { $_.ResultCode -eq 4 })
$hpOk  = @($hp   | Where-Object { $_.ResultCode -eq 2 })
$hpFailDays = @($hpF  | ForEach-Object { $_.Date.ToString('yyyy-MM-dd') } | Select-Object -Unique).Count
$hpOkDays   = @($hpOk | ForEach-Object { $_.Date.ToString('yyyy-MM-dd') } | Select-Object -Unique).Count
$lastFail = $hpF  | Sort-Object Date -Descending | Select-Object -First 1
$lastOk   = $hpOk | Sort-Object Date -Descending | Select-Object -First 1
$hpFailHR = (@($hpF | ForEach-Object { '0x{0:X8}' -f $_.HResult } | Select-Object -Unique) -join ',')
$hpFailUpd = (@($hpF | ForEach-Object { Short-Title $_.Title } | Select-Object -Unique | Select-Object -First 4) -join ';')

# non-HP failures (is it only HP?)
$oth = @($hist | Where-Object { $_.Title -notmatch $hpRx -and $_.ResultCode -eq 4 })
$othTitles = @($oth | Group-Object Title | Sort-Object Count -Descending)
$othTop = $null; $othTopHR = $null
if ($othTitles.Count -gt 0) {
    $othTop   = Short-Title $othTitles[0].Name
    $othTopHR = '0x{0:X8}' -f ($othTitles[0].Group | Select-Object -First 1).HResult
}

# --- 3. Pending / hidden updates (one WU search, 150s cap) -----------
$pendState = 'ok'
$pend = @()
$job = Start-Job -ScriptBlock {
    $r = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=0')
    foreach ($u in $r.Updates) { [pscustomobject]@{ Title = $u.Title; Hidden = [bool]$u.IsHidden; Downloaded = [bool]$u.IsDownloaded } }
}
if (Wait-Job $job -Timeout 150) {
    $pend = @(Receive-Job $job)
    if ($job.State -eq 'Failed') { $pendState = 'err' }
} else { $pendState = 'timeout'; Stop-Job $job }
Remove-Job $job -Force

$hpPend        = @($pend | Where-Object { $_.Title -match $hpRx })
$hpPendVisible = @($hpPend | Where-Object { -not $_.Hidden }).Count
$hpPendHidden  = @($hpPend | Where-Object { $_.Hidden }).Count
$hpPendDl      = @($hpPend | Where-Object { $_.Downloaded -and -not $_.Hidden }).Count
$othPendVis    = @($pend | Where-Object { $_.Title -notmatch $hpRx -and -not $_.Hidden }).Count
$totPendVis    = @($pend | Where-Object { -not $_.Hidden }).Count

# --- 4. HP printer / USB present now ----------------------------------
$hpUsb = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_03F0*' })
$hpUsbModel = $null
$prn = $hpUsb | Where-Object { $_.FriendlyName -match 'LaserJet|OfficeJet|DeskJet|Printer|MFP' } | Select-Object -First 1
if ($prn) { $hpUsbModel = $prn.FriendlyName }

# --- 5. HP USB driver packages already installed ----------------------
$hpDrv = @(Get-WindowsDriver -Online -All | Where-Object { $_.ClassName -eq 'USB' -and $_.ProviderName -match 'Hewlett|^HP' })
$hpDrvVer = (@($hpDrv | ForEach-Object { $_.Version } | Sort-Object -Unique) -join ',')

# --- 6. Policy state --------------------------------------------------
$excl = $null
foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update')) {
    $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
    if ($null -ne $v) { $excl = $v }
}
$drvEnrolled = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update' -ErrorAction SilentlyContinue).DriverUpdateEnrolled

# --- 7. Verdict -------------------------------------------------------
if (-not $histOk)                                   { $verdict = 'Unknown' }
elseif ($hpPendVisible -gt 0 -and $hpFailDays -ge 3){ $verdict = 'Looping' }
elseif ($hpPendVisible -gt 0)                       { $verdict = 'Pending' }
elseif ($hpPendHidden  -gt 0)                       { $verdict = 'Hidden' }
elseif ($hpFailDays    -gt 0)                       { $verdict = 'PastFailures' }
else                                                { $verdict = 'Clean' }

function V($x) { if ($null -eq $x -or "$x" -eq '') { return '' } else { return (Clean "$x") } }
function D($d) { if ($d) { return $d.Date.ToString('yyyy-MM-dd') } else { return '' } }

$fields = [ordered]@{
    Verdict        = $verdict
    Host           = $env:COMPUTERNAME
    Make           = V $cs.Manufacturer
    Model          = V $cs.Model
    Serial         = V $bios.SerialNumber
    OSBuild        = V $os.BuildNumber
    HpFailDays     = $hpFailDays
    HpFailEntries  = $hpF.Count
    HpOkDays       = $hpOkDays
    HpLastFail     = D $lastFail
    HpLastOk       = D $lastOk
    HpFailHR       = V $hpFailHR
    HpFailUpdates  = V $hpFailUpd
    HpPendVisible  = $hpPendVisible
    HpPendHidden   = $hpPendHidden
    HpPendDl       = $hpPendDl
    OtherPendVis   = $othPendVis
    TotPendVis     = $totPendVis
    PendSearch     = $pendState
    OtherFailCount = $othTitles.Count
    OtherFailTop   = V $othTop
    OtherFailTopHR = V $othTopHR
    HpUsbPresent   = $hpUsb.Count
    HpUsbModel     = V $hpUsbModel
    HpUsbInstalled = V $hpDrvVer
    ExclDrv        = V $excl
    DrvEnrolled    = V $drvEnrolled
    WinDays        = $days
    Ts             = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
}
$line = ($fields.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '|'
if ($line.Length -gt 2000) { $line = $line.Substring(0, 2000) }
Write-Output $line

if ($verdict -eq 'Looping' -or $verdict -eq 'Pending') { exit 1 } else { exit 0 }
