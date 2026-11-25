# =====================================================================================
#  Windows Device Onboarding Check
#  ---------------------------------------------------------------------------------
#  Weekly report: checks every Autopilot-built Windows device against the two
#  deployment groups, and flags devices in the BitLocker group that are not encrypted.
#
#  Runs on the Jenkins server via Jenkins (Windows PowerShell 5.1, SYSTEM, cert JWT auth).
#  Read only: this script never adds, removes or deletes anything.
#
#  Sends one email to Help Desk with a summary table and the PDF attached. The PDF carries
#  everything that needs action. A full CSV of every device is written to $OutFolder on the
#  server as the permanent record - it is NOT emailed.
# =====================================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================ SETTINGS ===============================================

$CutoffDate   = Get-Date '2026-08-20'          # only devices built on/after this date
$BitLockerGrp = 'YOUR_BITLOCKER_GROUP'
$PackagesGrp  = 'YOUR_PACKAGES_GROUP'

$From         = 'jenkins@example.com'
$To           = @('support@example.com')
$SmtpServer   = 'smtp.example.com'

$OutFolder    = 'D:\JenkinsLogs\Windows-Device-Onboarding-Check'
$EdgePath     = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

$ShowGoodStandingTable = $false  # $false = show a count only (keeps the PDF short long term)
                                 # good-standing devices accumulate forever, so the
                                 # table would grow without bound. The CSV keeps every device with
                                 # full detail; the PDF only needs what somebody has to act on.

# Graph app registration (your-automation-app)
$AppId      = 'YOUR_APP_CLIENT_ID'
$TenantId   = 'YOUR_TENANT_ID'
$Thumbprint = 'YOUR_CERT_THUMBPRINT'

# ============================ SETUP ==================================================

$RunDate  = Get-Date
$Stamp    = $RunDate.ToString('yyyyMMdd')
$Now      = $RunDate
$BuildNo  = if ($env:BUILD_NUMBER) { "build $($env:BUILD_NUMBER)" } else { "manual run" }

if (-not (Test-Path $OutFolder)) { New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null }

$PdfPath  = Join-Path $OutFolder "Device-Onboarding-Check_$Stamp.pdf"
# The running record. Every week's rows are appended here with a RunDate, so one file answers
# "when did this device first show up, and how long was it missing a group" - which no single
# weekly snapshot can. This is the file to open; the dated snapshots are just a rebuild safety net.
$HistPath = Join-Path $OutFolder "DeviceOnboarding-History.csv"
$TmpHtml  = Join-Path $env:TEMP "DeviceOnboarding_$Stamp.html"

Write-Host "Windows Device Onboarding Check"
Write-Host "  Run date : $($RunDate.ToString('yyyy-MM-dd HH:mm'))"
Write-Host "  Cutoff   : $($CutoffDate.ToString('yyyy-MM-dd'))"
Write-Host "  Output   : $OutFolder"
Write-Host ""

# ============================ AUTHENTICATION =========================================

$cert = Get-ChildItem Cert:\LocalMachine\My\ | Where-Object { $_.Thumbprint -eq $Thumbprint }
If (-not $cert) {
    Write-Host "Certificate not found. Thumbprint: $Thumbprint"
    Exit 1
}

$certHash   = [System.Convert]::ToBase64String($cert.GetCertHash())
$jwtHeader  = @{ alg = "RS256"; typ = "JWT"; x5t = $certHash } | ConvertTo-Json -Compress
$epoch      = [datetime]"1970-01-01T00:00:00Z"
$nowSec     = [int]([datetime]::UtcNow - $epoch).TotalSeconds
$jwtPayload = @{
    aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    iss = $AppId
    sub = $AppId
    jti = [guid]::NewGuid().ToString()
    nbf = $nowSec
    exp = $nowSec + 600
} | ConvertTo-Json -Compress

$toBase64Url = { param($bytes) [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
$headerB64   = & $toBase64Url ([System.Text.Encoding]::UTF8.GetBytes($jwtHeader))
$payloadB64  = & $toBase64Url ([System.Text.Encoding]::UTF8.GetBytes($jwtPayload))
$dataToSign  = [System.Text.Encoding]::UTF8.GetBytes("$headerB64.$payloadB64")
$rsa         = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
$signature   = & $toBase64Url ($rsa.SignData($dataToSign, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))

$tokenBody = @{
    client_id             = $AppId
    scope                 = "https://graph.microsoft.com/.default"
    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion      = "$headerB64.$payloadB64.$signature"
    grant_type            = "client_credentials"
}

Try {
    $token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $tokenBody -ErrorAction Stop
}
Catch {
    Write-Host "Token request failed: $_"
    Exit 1
}

$Headers = @{ Authorization = "Bearer $($token.access_token)" }
# NOTE: PowerShell cannot add two hashtables. Clone, never use $Headers + @{...}
$HeadersEC = @{}
foreach ($k in $Headers.Keys) { $HeadersEC[$k] = $Headers[$k] }
$HeadersEC['ConsistencyLevel'] = 'eventual'

Write-Host "Authenticated to Microsoft Graph."

# ============================ HELPERS ================================================

function Get-GraphAll {
    param([string]$Uri, [hashtable]$H = $Headers)
    $out = @()
    $next = $Uri
    while ($next) {
        $r = Invoke-RestMethod -Uri $next -Headers $H -Method Get -ErrorAction Stop
        if ($r.value) { $out += $r.value }
        $next = $r.'@odata.nextLink'
    }
    return $out
}

function Get-GroupMemberSet {
    param([string]$DisplayName)
    $g = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$DisplayName'&`$select=id,displayName" -Headers $Headers -Method Get).value
    if (-not $g) { throw "Group not found: $DisplayName" }
    $members = Get-GraphAll "https://graph.microsoft.com/v1.0/groups/$($g[0].id)/members?`$select=id,displayName,deviceId&`$top=999"
    return [pscustomobject]@{ Id = $g[0].id; Name = $DisplayName; Members = $members }
}

function HtmlEnc { param([string]$s) if ($null -eq $s) { return '' } [System.Net.WebUtility]::HtmlEncode($s) }

function Fmt-Date {
    param($d)
    if (-not $d) { return 'never' }
    $dt = [datetime]$d
    if ($dt.Date -eq $Now.Date) { return 'Today' }
    return $dt.ToString('dd MMM')
}

# ============================ COLLECT DATA ===========================================

Write-Host "Reading groups..."
$blGroup = Get-GroupMemberSet $BitLockerGrp
$pkGroup = Get-GroupMemberSet $PackagesGrp

$blSet = @{}; foreach ($m in $blGroup.Members) { if ($m.deviceId) { $blSet[$m.deviceId.ToLower()] = $true } }
$pkSet = @{}; foreach ($m in $pkGroup.Members) { if ($m.deviceId) { $pkSet[$m.deviceId.ToLower()] = $true } }
Write-Host "  $BitLockerGrp : $($blGroup.Members.Count) objects"
Write-Host "  $PackagesGrp : $($pkGroup.Members.Count) objects"

Write-Host "Reading Intune managed devices..."
$managed = Get-GraphAll "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,deviceName,azureADDeviceId,isEncrypted,enrolledDateTime,autopilotEnrolled,userPrincipalName,userDisplayName,lastSyncDateTime,model,complianceState&`$top=999"
$byDeviceId = @{}
foreach ($d in $managed) { if ($d.azureADDeviceId) { $byDeviceId[$d.azureADDeviceId.ToLower()] = $d } }
Write-Host "  $($managed.Count) Windows devices"

Write-Host "Reading BitLocker recovery keys..."
$keys = Get-GraphAll "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$select=id,deviceId&`$top=999" $HeadersEC
$keySet = @{}; foreach ($k in $keys) { if ($k.deviceId) { $keySet[$k.deviceId.ToLower()] = $true } }
Write-Host "  $($keySet.Count) devices with an escrowed key"

Write-Host "Reading Entra device sign-in dates..."
$entra = Get-GraphAll "https://graph.microsoft.com/v1.0/devices?`$filter=operatingSystem eq 'Windows'&`$select=deviceId,approximateLastSignInDateTime,accountEnabled,trustType&`$top=999"
$entraSet = @{}; foreach ($e in $entra) { if ($e.deviceId) { $entraSet[$e.deviceId.ToLower()] = $e } }

Write-Host "Reading Entra audit log for group membership changes..."
$auditMap = @{}   # "deviceName|GroupLabel" -> @{ When; By }
Try {
    $events = @()
    $uri = "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=activityDisplayName eq 'Add member to group'&`$top=999"
    $pages = 0
    while ($uri -and $pages -lt 10) {
        $r = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        $events += $r.value
        $uri = $r.'@odata.nextLink'
        $pages++
    }
    foreach ($e in $events) {
        $ids = ($e.targetResources.id) -join ' '
        $label = $null
        if ($ids -match [regex]::Escape($blGroup.Id)) { $label = 'BitLocker' }
        elseif ($ids -match [regex]::Escape($pkGroup.Id)) { $label = 'Packages' }
        if (-not $label) { continue }
        $dev = $e.targetResources | Where-Object { $_.type -eq 'Device' }
        foreach ($d in $dev) {
            if (-not $d.displayName) { continue }
            $key = "$($d.displayName)|$label"
            $when = [datetime]$e.activityDateTime
            if ((-not $auditMap.ContainsKey($key)) -or ($when -gt $auditMap[$key].When)) {
                $auditMap[$key] = @{ When = $when; By = $e.initiatedBy.user.userPrincipalName }
            }
        }
    }
    Write-Host "  $($events.Count) events scanned, $($auditMap.Count) relevant group changes"
}
Catch {
    Write-Host "  Audit log unavailable, attribution columns will be blank: $_"
}

function Get-Attribution {
    param([string]$DeviceName, [string]$Label)
    $key = "$DeviceName|$Label"
    if ($auditMap.ContainsKey($key)) {
        $a = $auditMap[$key]
        $who = $a.By
        if ($who) { $who = ($who -split '@')[0] } else { $who = 'unknown' }
        return "$($a.When.ToString('dd MMM')) by $who"
    }
    return $null
}

# ============================ CLASSIFY ===============================================

function Get-DeviceClass {
    param($Device)
    $id       = $Device.azureADDeviceId.ToLower()
    $lastSync = [datetime]$Device.lastSyncDateTime
    $enrolled = [datetime]$Device.enrolledDateTime
    $quiet    = [math]::Max(0, [math]::Floor(($Now - $lastSync).TotalDays))
    $alive    = [math]::Floor(($lastSync - $enrolled).TotalDays)

    $signIn = $null
    if ($entraSet.ContainsKey($id) -and $entraSet[$id].approximateLastSignInDateTime) {
        $signIn = [datetime]$entraSet[$id].approximateLastSignInDateTime
    }

    if ($quiet -le 7) { return [pscustomobject]@{ Days = $quiet; Class = 'Active'; Flag = $false } }
    if ($signIn -and (($signIn - $lastSync).TotalDays -gt 7)) {
        return [pscustomobject]@{ Days = $quiet; Class = 'Alive in Entra, quiet in Intune'; Flag = $true }
    }
    if ($alive -le 1) { return [pscustomobject]@{ Days = $quiet; Class = 'Never issued'; Flag = $false } }
    return [pscustomobject]@{ Days = $quiet; Class = 'Went quiet'; Flag = $false }
}

$autopilot = $managed | Where-Object {
    $_.autopilotEnrolled -and $_.enrolledDateTime -and ([datetime]$_.enrolledDateTime) -ge $CutoffDate
} | Sort-Object { [datetime]$_.enrolledDateTime } -Descending

Write-Host "Autopilot devices built since cutoff: $($autopilot.Count)"

$rows = @()
foreach ($d in $autopilot) {
    $id  = $d.azureADDeviceId.ToLower()
    $cls = Get-DeviceClass $d
    $inBL = $blSet.ContainsKey($id)
    $inPK = $pkSet.ContainsKey($id)
    $rows += [pscustomobject]@{
        Section     = ''
        Device      = $d.deviceName
        User        = $(if ($d.userDisplayName) { $d.userDisplayName } else { '' })
        Upn         = $d.userPrincipalName
        Model       = $d.model
        Built       = ([datetime]$d.enrolledDateTime).ToString('yyyy-MM-dd')
        LastSeen    = ([datetime]$d.lastSyncDateTime).ToString('yyyy-MM-dd')
        DaysQuiet   = $cls.Days
        Class       = $cls.Class
        NeedsLook   = $cls.Flag
        InBitLocker = $inBL
        InPackages  = $inPK
        Encrypted   = [bool]$d.isEncrypted
        KeyEscrowed = $keySet.ContainsKey($id)
        BitLockerAdd = Get-Attribution $d.deviceName 'BitLocker'
        PackagesAdd  = Get-Attribution $d.deviceName 'Packages'
    }
}

# Section 1: built since cutoff, missing one or both groups
$missing = $rows | Where-Object { (-not $_.InBitLocker) -or (-not $_.InPackages) }
foreach ($r in $missing) { $r.Section = '1 - Missing a group' }

# Section 2: in the BitLocker group but not encrypted (whole group, not just new devices)
$notEncrypted = @()
foreach ($m in $blGroup.Members) {
    if (-not $m.deviceId) { continue }
    $id = $m.deviceId.ToLower()
    if (-not $byDeviceId.ContainsKey($id)) { continue }   # stale object, out of scope by design
    $d = $byDeviceId[$id]
    if ($d.isEncrypted -and $keySet.ContainsKey($id)) { continue }
    $cls = Get-DeviceClass $d
    $notEncrypted += [pscustomobject]@{
        Section     = '2 - Not encrypted'
        Device      = $d.deviceName
        User        = $(if ($d.userDisplayName) { $d.userDisplayName } else { '' })
        Upn         = $d.userPrincipalName
        Model       = $d.model
        Built       = ([datetime]$d.enrolledDateTime).ToString('yyyy-MM-dd')
        LastSeen    = ([datetime]$d.lastSyncDateTime).ToString('yyyy-MM-dd')
        DaysQuiet   = $cls.Days
        Class       = $cls.Class
        NeedsLook   = $cls.Flag
        InBitLocker = $true
        InPackages  = $pkSet.ContainsKey($id)
        Encrypted   = [bool]$d.isEncrypted
        KeyEscrowed = $keySet.ContainsKey($id)
        BitLockerAdd = Get-Attribution $d.deviceName 'BitLocker'
        PackagesAdd  = Get-Attribution $d.deviceName 'Packages'
    }
}

# Section 3: good standing
$good = $rows | Where-Object { $_.InBitLocker -and $_.InPackages -and $_.Encrypted -and $_.KeyEscrowed }
foreach ($r in $good) { $r.Section = '3 - Good standing' }

$cntTotal   = $autopilot.Count
$cntGood    = @($good).Count
$cntMissing = @($missing).Count
$cntNotEnc  = @($notEncrypted).Count
$cntLook    = @($rows + $notEncrypted | Where-Object { $_.NeedsLook }).Count
$cntAction  = $cntMissing + $cntNotEnc

Write-Host ""
Write-Host "  Fully set up      : $cntGood"
Write-Host "  Missing a group   : $cntMissing"
Write-Host "  Not encrypted     : $cntNotEnc"
Write-Host "  Needs a look      : $cntLook"

# ============================ WORDING ================================================

if ($cntAction -eq 0) {
    $Subject  = "New device onboarding check: all clear ($($RunDate.ToString('dd MMM yyyy')))"
    $LeadLine = "All $cntTotal devices built since $($CutoffDate.ToString('dd MMMM yyyy')) are fully set up. No action needed this week."
} else {
    $word     = if ($cntAction -eq 1) { "1 device needs" } else { "$cntAction devices need" }
    $Subject  = "New device onboarding check: $word attention ($($RunDate.ToString('dd MMM yyyy')))"
    $LeadLine = "Weekly check of Autopilot devices against the two deployment groups. <strong>$word attention this week.</strong> Full detail is in the attached PDF."
}

# ============================ HTML BUILDERS ==========================================

$PdfCss = @"
<style>
@page { size: A4 portrait; margin: 14mm 13mm; }
body {font-family: Calibri, Segoe UI, Arial, sans-serif; font-size: 10pt; color:#1f1f1f; margin:0;}
.band {border-bottom:3px solid #1c5cab; padding-bottom:10px; margin-bottom:16px;}
.band .t {font-size:18pt; font-weight:600; color:#12365f;}
.band .s {font-size:9.5pt; color:#5a5a55; margin-top:3px;}
.meta {width:100%; border-collapse:collapse; font-size:9pt; margin-bottom:18px;}
.meta td {padding:3px 0;}
.meta td.k {color:#5a5a55; width:130px;}
h2 {font-size:12pt; color:#12365f; margin:22px 0 4px 0; border-bottom:1px solid #d8d8d3; padding-bottom:4px;}
p.sub {font-size:9pt; color:#5a5a55; margin:0 0 8px 0;}
table.data {border-collapse:collapse; width:100%; font-size:9pt; margin-bottom:8px;}
table.data th {background:#f2f2ef; border:1px solid #d8d8d3; padding:5px 7px; text-align:left; font-weight:600; white-space:nowrap;}
table.data td {border:1px solid #d8d8d3; padding:5px 7px; vertical-align:top;}
table.data tr:nth-child(even) td {background:#fafaf8;}
table.data tr {page-break-inside:avoid;}
td.c, th.c {text-align:center;}
td.dev, td.dt, td.grp, td.enc {white-space:nowrap;}
.miss {color:#a11212; font-weight:600;}
.have {color:#5a5a55;}
.tag {display:inline-block; padding:1px 7px; border-radius:9px; font-size:8.5pt; font-weight:600;}
.tag-never {background:#fdf0dc; color:#8a5a00;}
.tag-quiet {background:#fdf0dc; color:#8a5a00;}
.tag-alive {background:#fbe3e3; color:#a11212;}
.tag-active {background:#eaf3ea; color:#2c6b2c;}
table.kpi {border-collapse:collapse; margin-bottom:18px; width:100%;}
table.kpi td {border:1px solid #d8d8d3; padding:9px 6px; text-align:center;}
table.kpi .n {font-size:18pt; font-weight:600; color:#12365f; display:block;}
table.kpi .l {font-size:8pt; color:#5a5a55; text-transform:uppercase; letter-spacing:.4px;}
.note {border-left:3px solid #eda100; background:#fdf6e6; padding:8px 11px; font-size:9pt; margin:10px 0 0 0;}
.note.blue {border-left-color:#1c5cab; background:#eef4fc;}
.none {font-size:9.5pt; color:#2c6b2c; padding:6px 0;}
ol {margin:4px 0 0 16px; padding:0;} ol li {margin-bottom:4px;}
dl {margin:6px 0 0 0; font-size:9pt;}
dt {font-weight:600; color:#12365f; margin-top:6px;}
dd {margin:1px 0 0 0; color:#444;}
.foot {border-top:1px solid #d8d8d3; margin-top:26px; padding-top:8px; font-size:8pt; color:#7a7a75;}
</style>
"@

function ClassTag {
    param([string]$Class)
    switch ($Class) {
        'Active'       { return '<span class="tag tag-active">Active</span>' }
        'Never issued' { return '<span class="tag tag-never">Never issued</span>' }
        'Went quiet'   { return '<span class="tag tag-quiet">Went quiet</span>' }
        default        { return '<span class="tag tag-alive">' + (HtmlEnc $Class) + '</span>' }
    }
}

$sb = New-Object System.Text.StringBuilder
$null = $sb.Append("<html><head><meta charset='utf-8'>$PdfCss</head><body>")
$null = $sb.Append("<div class='band'><div class='t'>New Device Onboarding Check</div><div class='s'>Weekly compliance report &middot; IT Infrastructure</div></div>")

$null = $sb.Append("<table class='meta'>")
$null = $sb.Append("<tr><td class='k'>Report date</td><td>$($RunDate.ToString('dddd d MMMM yyyy'))</td></tr>")
$null = $sb.Append("<tr><td class='k'>Scope</td><td>Windows devices built through Autopilot on or after $($CutoffDate.ToString('d MMMM yyyy'))</td></tr>")
$null = $sb.Append("<tr><td class='k'>Groups checked</td><td>$BitLockerGrp &nbsp;|&nbsp; $PackagesGrp</td></tr>")
$null = $sb.Append("<tr><td class='k'>Source</td><td>Microsoft Intune, Microsoft Entra and the Entra audit log</td></tr>")
$null = $sb.Append("<tr><td class='k'>Generated by</td><td>Jenkins job Windows-Device-Onboarding-Check, $BuildNo</td></tr>")
$null = $sb.Append("</table>")

$null = $sb.Append("<table class='kpi'><tr>")
$null = $sb.Append("<td><span class='n'>$cntTotal</span><span class='l'>Built since $($CutoffDate.ToString('d MMM'))</span></td>")
$null = $sb.Append("<td><span class='n'>$cntGood</span><span class='l'>Fully set up</span></td>")
$null = $sb.Append("<td><span class='n'>$cntMissing</span><span class='l'>Missing a group</span></td>")
$null = $sb.Append("<td><span class='n'>$cntNotEnc</span><span class='l'>Not encrypted</span></td>")
$null = $sb.Append("</tr></table>")

# ---- Section 1
$null = $sb.Append("<h2>1. Devices missing a group</h2>")
$null = $sb.Append("<p class='sub'>These devices were built through Autopilot but were never added to one or both deployment groups. Until they are added, BitLocker will not encrypt them and Microsoft 365 Apps will not install.</p>")
if ($cntMissing -eq 0) {
    $null = $sb.Append("<p class='none'>No devices are missing a group this week.</p>")
} else {
    $null = $sb.Append("<table class='data'><tr><th class='dev'>Device</th><th>Assigned to</th><th class='c dt'>Built</th><th class='c dt'>Last seen</th><th class='c grp'>BitLocker group</th><th class='c grp'>Packages group</th><th class='c enc'>Encrypted</th><th class='att'>Last group change</th></tr>")
    foreach ($r in $missing) {
        $bl = if ($r.InBitLocker) { "<td class='c grp have'>In group</td>" } else { "<td class='c grp miss'>Missing</td>" }
        $pk = if ($r.InPackages)  { "<td class='c grp have'>In group</td>" } else { "<td class='c grp miss'>Missing</td>" }
        $en = if ($r.Encrypted)   { "<td class='c enc have'>Yes</td>" }      else { "<td class='c enc miss'>No</td>" }
        $att = @()
        if ($r.BitLockerAdd) { $att += "BitLocker, $($r.BitLockerAdd)" }
        if ($r.PackagesAdd)  { $att += "Packages, $($r.PackagesAdd)" }
        $attTxt = if ($att.Count) { HtmlEnc ($att -join '; ') } else { '<em>no record</em>' }
        $usr = if ($r.User) { HtmlEnc $r.User } else { '<em>no user assigned</em>' }
        $null = $sb.Append("<tr><td class='dev'>$(HtmlEnc $r.Device)</td><td>$usr</td><td class='c dt'>$(Fmt-Date $r.Built)</td><td class='c dt'>$(Fmt-Date $r.LastSeen)</td>$bl$pk$en<td class='att'>$attTxt</td></tr>")
    }
    $null = $sb.Append("</table>")
}

# ---- Section 2
$null = $sb.Append("<h2>2. In the BitLocker group but not yet encrypted</h2>")
$null = $sb.Append("<p class='sub'>The encryption policy has reached these devices, but encryption has not completed or no recovery key has been saved to Entra. Without a saved key, a device cannot be recovered if it ever prompts for one.</p>")
if ($cntNotEnc -eq 0) {
    $null = $sb.Append("<p class='none'>Every device in the BitLocker group is encrypted with a recovery key saved.</p>")
} else {
    $null = $sb.Append("<table class='data'><tr><th class='dev'>Device</th><th>Assigned to</th><th class='mdl'>Model</th><th class='c dt'>Built</th><th class='c dt'>Last seen</th><th class='c enc'>Encrypted</th><th class='c enc'>Key saved</th><th class='c'>Status</th><th class='att'>Added to group</th></tr>")
    foreach ($r in $notEncrypted) {
        $en = if ($r.Encrypted)   { "<td class='c enc have'>Yes</td>" } else { "<td class='c enc miss'>No</td>" }
        $ky = if ($r.KeyEscrowed) { "<td class='c enc have'>Yes</td>" } else { "<td class='c enc miss'>No</td>" }
        $attTxt = if ($r.BitLockerAdd) { HtmlEnc $r.BitLockerAdd } else { '<em>no record</em>' }
        $usr = if ($r.User) { HtmlEnc $r.User } else { '<em>no user assigned</em>' }
        $null = $sb.Append("<tr><td class='dev'>$(HtmlEnc $r.Device)</td><td>$usr</td><td class='mdl'>$(HtmlEnc $r.Model)</td><td class='c dt'>$(Fmt-Date $r.Built)</td><td class='c dt'>$(Fmt-Date $r.LastSeen)</td>$en$ky<td class='c'>$(ClassTag $r.Class)</td><td class='att'>$attTxt</td></tr>")
    }
    $null = $sb.Append("</table>")
}

# ---- Section 3
$null = $sb.Append("<h2>3. Devices in good standing</h2>")
if (-not $ShowGoodStandingTable) {
    # Count only. Singular/plural and the zero case are handled here too - this branch is now the
    # default, so "0 devices ... are in both groups" would have been the normal week's wording.
    if ($cntGood -eq 0) {
        $null = $sb.Append("<p class='none'>No devices are fully set up yet. Every device built since $($CutoffDate.ToString('d MMMM yyyy')) appears in a section above.</p>")
    } else {
        $isare = if ($cntGood -eq 1) { 'device is' } else { 'devices are' }
        $null = $sb.Append("<p class='none'><strong>$cntGood $isare fully set up</strong> &mdash; built since $($CutoffDate.ToString('d MMMM yyyy')), in both groups, encrypted, with a recovery key saved. No action needed. They are not listed individually here, but every one is in the weekly data file kept on the server.</p>")
    }
} elseif ($cntGood -eq 0) {
    $null = $sb.Append("<p class='sub'>None yet.</p>")
} else {
    $null = $sb.Append("<p class='sub'>Built since $($CutoffDate.ToString('d MMMM yyyy')), in both groups, encrypted, with a recovery key saved. No action needed.</p>")
    $null = $sb.Append("<table class='data'><tr><th class='dev'>Device</th><th>Assigned to</th><th class='c dt'>Built</th><th class='c dt'>Last seen</th><th class='c'>Status</th><th class='att'>Set up by</th></tr>")
    foreach ($r in $good) {
        $attTxt = if ($r.BitLockerAdd) { HtmlEnc $r.BitLockerAdd } else { '<em>no record</em>' }
        $null = $sb.Append("<tr><td class='dev'>$(HtmlEnc $r.Device)</td><td>$(HtmlEnc $r.User)</td><td class='c dt'>$(Fmt-Date $r.Built)</td><td class='c dt'>$(Fmt-Date $r.LastSeen)</td><td class='c'><span class='tag tag-active'>Complete</span></td><td class='att'>$attTxt</td></tr>")
    }
    $null = $sb.Append("</table>")
}

# ---- Glossary and actions
$null = $sb.Append(@"
<h2>How to read this report</h2>
<dl>
  <dt>Built</dt><dd>The date the device completed Autopilot enrolment into Intune.</dd>
  <dt>Last seen</dt><dd>The last time the device checked in with Intune. A device that has not checked in cannot receive policy or apps.</dd>
  <dt>Never issued</dt><dd>The device stopped checking in within a day of being built, which usually means it is still in stock and has not been handed to a user.</dd>
  <dt>Alive in Entra, quiet in Intune</dt><dd>The user is still signing in, but Intune has lost contact with the device. This is a management failure rather than a dead record, and is worth investigating.</dd>
  <dt>Encrypted</dt><dd>Confirmed two ways: the Intune encryption flag, and a matching BitLocker recovery key saved in Entra. Both must be true. This avoids false alarms on devices where encryption is temporarily suspended.</dd>
  <dt>Set up by / Last group change</dt><dd>Taken from the Entra audit log: the admin account that added the device to the group, and when. Microsoft does not record who imaged a device, so this is the closest available attribution. The Entra audit log only retains 30 days, so anything older shows as no record.</dd>
</dl>
<div class='note'><strong>What to do</strong>
<ol>
  <li>In Entra, add each device in section 1 to any group marked <span class='miss'>Missing</span>.</li>
  <li>Check the devices in section 2 and bring them online if they have been issued.</li>
  <li>Nothing else is required. Encryption and app installation follow automatically once a device is in the correct group and next checks in.</li>
</ol></div>
<div class='note blue'>This report is generated automatically and reports only. It does not add, remove, or change anything in Intune or Entra.</div>
"@)

$null = $sb.Append("<div class='foot'>Windows-Device-Onboarding-Check &middot; $BuildNo &middot; run $($RunDate.ToString('yyyy-MM-dd HH:mm'))<br>Questions: you@example.com</div>")
$null = $sb.Append("</body></html>")

Set-Content -Path $TmpHtml -Value $sb.ToString() -Encoding UTF8
Write-Host "Report HTML written to $TmpHtml"

# ============================ RENDER PDF =============================================

$pdfOk = $false
if (Test-Path $EdgePath) {
    Try {
        $edgeArgs = @(
            '--headless=new', '--disable-gpu', '--no-first-run',
            "--user-data-dir=$env:TEMP\edge-onboarding-report",
            '--no-pdf-header-footer',
            "--print-to-pdf=$PdfPath",
            $TmpHtml
        )
        $p = Start-Process -FilePath $EdgePath -ArgumentList $edgeArgs -PassThru -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 3
        # Edge can exit non-zero on success, so test for the file rather than the exit code
        if (Test-Path $PdfPath) {
            $pdfOk = $true
            Write-Host "PDF created: $PdfPath ($([math]::Round((Get-Item $PdfPath).Length/1KB)) KB)"
        } else {
            Write-Host "Edge ran (exit $($p.ExitCode)) but no PDF was produced."
        }
    }
    Catch { Write-Host "PDF generation failed: $_" }
} else {
    Write-Host "Edge not found at $EdgePath, sending without a PDF."
}

# ============================ CSV ====================================================

$csvRows = @()
$csvRows += $missing
$csvRows += $notEncrypted
$csvRows += $good

# RunDate FIRST, so every row says which week it came from once they are all in one file.
$RunStamp = $RunDate.ToString('yyyy-MM-dd')
$csvOut = $csvRows | Select-Object @{n='RunDate';e={ $RunStamp }}, @{n='Event';e={ '' }},
    Section, Device, User, Upn, Model, Built, LastSeen, DaysQuiet, Class,
    InBitLocker, InPackages, Encrypted, KeyEscrowed, BitLockerAdd, PackagesAdd

# What counts as "this device changed". Deliberately NOT LastSeen or DaysQuiet - those move every
# single week on every device, which would make every row a "change" and defeat the whole point.
function Get-DeviceState {
    param($r)
    '{0}|{1}|{2}|{3}|{4}|{5}' -f $r.Section, $r.InBitLocker, $r.InPackages, $r.Encrypted, $r.KeyEscrowed, $r.Class
}

# NO per-run CSV any more (). Writing DeviceOnboarding_<date>.csv every week is
# exactly the pile-up of near-identical files this change removes - 4 of them already held 49 rows
# for what is really 22 events. The history file below is the single record. It is written via a
# temp file and Move-Item, so a crash cannot truncate it, and the weekly PDFs remain on disk.

# ---- Append to the running history -------------------------------------------------
# NOT Export-Csv -Append. A re-run - a manual Build Now after a failed build, say - would
# append a second copy of the same day and quietly double-count it in the one file whose whole
# job is to be the permanent record. Instead: drop any rows already carrying today's RunDate,
# then write old + new. Re-running is idempotent.
# Written to a temp file and moved into place, so a crash mid-write cannot truncate the history.
Try {
    $prior = @()
    if (Test-Path $HistPath) {
        $all   = @(Import-Csv $HistPath)
        $prior = @($all | Where-Object { $_.RunDate -ne $RunStamp })
        $dropped = $all.Count - $prior.Count
        if ($dropped) { Write-Host "  History: replacing $dropped row(s) already recorded for $RunStamp" }
    }

    # Only record a device when its state CHANGED. A weekly snapshot would repeat every
    # good laptop forever - 9 of this week's 18 needed no action and would be identical rows
    # week after week, burying the handful of rows that mean something. One row per device per
    # state change gives the same answers ("when did this get fixed", "how long was it missing")
    # in a file that stays readable for years.
    $lastState = @{}
    foreach ($h in ($prior | Sort-Object RunDate)) { $lastState[$h.Device] = Get-DeviceState $h }

    $changed = @()
    foreach ($r in $csvOut) {
        $now = Get-DeviceState $r
        if (-not $lastState.ContainsKey($r.Device)) { $r.Event = 'First seen'; $changed += $r }
        elseif ($lastState[$r.Device] -ne $now)     { $r.Event = 'Changed';    $changed += $r }
    }
    $unchanged = @($csvOut).Count - @($changed).Count

    if ($changed.Count) {
        $tmpHist = "$HistPath.tmp"
        @($prior + $changed) | Export-Csv -Path $tmpHist -NoTypeInformation -Encoding UTF8
        Move-Item -Path $tmpHist -Destination $HistPath -Force
    }
    Write-Host "History: $($changed.Count) new/changed row(s), $unchanged unchanged and skipped ($(@($prior).Count + @($changed).Count) rows total)"
}
Catch {
    # A broken history must never cost us the weekly report - the snapshot above already saved it.
    Write-Host "WARNING: could not update the history file: $_"
}

# ============================ EMAIL ==================================================

# Inline styles only, deliberately no <style> block. Ticketing systems (Freshservice confirmed,
# ) strip a <head><style> block off inbound mail before rendering the ticket body,
# which flattened this table to plain default borders. Every style below has to travel on the
# element itself to survive that.
$tdBase    = "border:1px solid #d8d8d3;padding:7px 9px;font-family:Calibri,Segoe UI,Arial,sans-serif;font-size:10.5pt;color:#1f1f1f;"
$thBase    = "$tdBase background:#f2f2ef;text-align:left;font-weight:600;"
$tdNumOk   = "$tdBase text-align:center;width:70px;font-weight:600;font-size:12pt;color:#12365f;"
$tdNumFlag = "$tdBase text-align:center;width:70px;font-weight:600;font-size:12pt;color:#a11212;"
$tdFlagBg  = "$tdBase background:#fdf3f3;"

$tdMissing   = if ($cntMissing -gt 0) { $tdNumFlag } else { $tdNumOk }
$tdMissingLbl = if ($cntMissing -gt 0) { $tdFlagBg } else { $tdBase }
$tdNotEnc    = if ($cntNotEnc -gt 0)  { $tdNumFlag } else { $tdNumOk }
$tdNotEncLbl  = if ($cntNotEnc -gt 0)  { $tdFlagBg } else { $tdBase }

$EmailBody = @"
<html><head><meta charset='utf-8'></head>
<body style="font-family:Calibri,Segoe UI,Arial,sans-serif;font-size:11pt;color:#1f1f1f;margin:0;">
<div style="background:#1c5cab;color:#fff;padding:13px 22px;">
<div style="font-size:15pt;font-weight:600;">New Device Onboarding Check</div>
<div style="font-size:9.5pt;opacity:.9;margin-top:2px;">Weekly automated review &middot; devices built since $($CutoffDate.ToString('d MMMM yyyy'))</div>
</div>
<div style="padding:16px 22px 0 22px;">
<p>$LeadLine</p>
<table style="border-collapse:collapse;width:100%;margin:4px 0 14px 0;">
<tr><th style="$thBase">&nbsp;</th><th style="$thBase">Result</th></tr>
<tr><td style="$tdNumOk">$cntTotal</td><td style="$tdBase">Devices built since $($CutoffDate.ToString('d MMMM yyyy'))</td></tr>
<tr><td style="$tdNumOk">$cntGood</td><td style="$tdBase">Fully set up: in both groups, encrypted, recovery key saved</td></tr>
<tr><td style="$tdMissing">$cntMissing</td><td style="$tdMissingLbl">Missing from a deployment group, needs adding in Entra</td></tr>
<tr><td style="$tdNotEnc">$cntNotEnc</td><td style="$tdNotEncLbl">In the BitLocker group but not encrypted, needs checking</td></tr>
</table>
<p>Groups checked: <strong>$BitLockerGrp</strong> and <strong>$PackagesGrp</strong>.
Once a device is in the correct group, encryption and app installation follow automatically at its next check in.</p>
</div>
<div style="border-top:1px solid #d8d8d3;margin:18px 22px 0 22px;padding-top:10px;font-size:8.5pt;color:#7a7a75;">
Generated automatically by Jenkins job <strong>Windows-Device-Onboarding-Check</strong>, $BuildNo, run $($RunDate.ToString('d MMM yyyy HH:mm')).<br>
This job reports only; it does not change anything in Intune or Entra.<br>
Questions: you@example.com</div>
</body></html>
"@

# Plain-text twin of the message above. Required: the mail is sent as multipart/alternative with
# BOTH parts, because this relay silently delivered a -BodyAsHtml message as plain text on the AFD
# monitor and the recipient got raw markup. See the Send-MailMessage writeup in the notes.
$plainLead = ($LeadLine -replace '<[^>]+>', '')
$PlainBody = @"
New Device Onboarding Check
Weekly automated review - devices built since $($CutoffDate.ToString('d MMMM yyyy'))

$plainLead

  $cntTotal  Devices built since $($CutoffDate.ToString('d MMMM yyyy'))
  $cntGood  Fully set up: in both groups, encrypted, recovery key saved
  $cntMissing  Missing from a deployment group, needs adding in Entra
  $cntNotEnc  In the BitLocker group but not encrypted, needs checking

Groups checked: $BitLockerGrp and $PackagesGrp.
Once a device is in the correct group, encryption and app installation follow
automatically at its next check in.

Full detail is in the attached PDF.

Jenkins job Windows-Device-Onboarding-Check, $BuildNo, run $($RunDate.ToString('d MMM yyyy HH:mm')).
This job reports only; it does not change anything in Intune or Entra.
Questions: you@example.com
"@

# The CSV is deliberately NOT attached (). The PDF carries everything that
# needs action, which is all Help Desk uses. The CSV exists as the permanent record - group-add
# attribution comes from directoryAudits, which only retains ~30 days - and that job is done by
# the file sitting in $OutFolder on the Jenkins server, kept alongside 52 builds of history.
$attachments = @()
if ($pdfOk) { $attachments += $PdfPath }

$mail = $null
Try {
    # NOT Send-MailMessage -BodyAsHtml. This relay delivered exactly that as plain text on the
    # AFD monitor (build 1) and the recipient got raw markup. Building the message by hand with
    # BOTH an explicit text/plain and text/html AlternateView is what fixed it there, and is now
    # running on both certificate monitors.
    $mail = New-Object Net.Mail.MailMessage
    $mail.From = New-Object Net.Mail.MailAddress($From)
    foreach ($t in $To) { $mail.To.Add($t) }
    $mail.Subject         = $Subject
    $mail.SubjectEncoding = [Text.Encoding]::UTF8

    $mail.AlternateViews.Add([Net.Mail.AlternateView]::CreateAlternateViewFromString(
        $PlainBody, [Text.Encoding]::UTF8, 'text/plain'))
    $mail.AlternateViews.Add([Net.Mail.AlternateView]::CreateAlternateViewFromString(
        $EmailBody, [Text.Encoding]::UTF8, 'text/html'))

    # No empty-array problem here - an empty loop simply adds nothing, so a failed PDF render
    # still lets the summary go out.
    if (-not $attachments.Count) { Write-Host "WARNING: no PDF produced - sending the summary without an attachment." }
    foreach ($a in $attachments) { $mail.Attachments.Add((New-Object Net.Mail.Attachment($a))) }

    (New-Object Net.Mail.SmtpClient($SmtpServer)).Send($mail)
    Write-Host "Email sent to: $($To -join ', ')  (attachments: $($attachments.Count))"
}
Catch {
    Write-Host "Failed to send email: $_"
    Exit 1
}
Finally {
    if ($mail) { $mail.Dispose() }   # releases the handle on the attached PDF
}

# ============================ CLEANUP ================================================

if (Test-Path $TmpHtml) { Remove-Item $TmpHtml -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Done. $cntAction action item(s) reported."
Exit 0
