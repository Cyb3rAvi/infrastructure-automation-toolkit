# =====================================================================================
#  AFD Certificate Auto Revalidation
#  ---------------------------------------------------------------------------------
#  Renews Azure Front Door managed certificates on APEX domains, which never
#  auto-rotate (Microsoft: they go to "Pending Revalidation" 45 days before expiry
#  and wait for a new _dnsauth TXT value).
#
#  Separate from AFD-Certificate-Expiry-Monitor on purpose. That job only alerts;
#  this one reads Azure itself and does not depend on the monitor having run.
#
#  One Jenkins job, three timer triggers. The mode comes from the clock:
#    Mon 18:00-23:59  FIX    certs <= 21 days -> regenerate token + swap _dnsauth
#    Tue 00:00-05:59  CHECK  secret renewed? retry only if NOT Approved and not renewed
#    Tue 06:00-11:59  FINAL  secret renewed? email success or manual-lookup list
#  State is passed between runs in AutoRevalidation-State.json next to this script,
#  so a reboot between runs loses nothing.
#
#  Emails:  FIX    only if something was due
#           CHECK  never (a crash is saved to the state file and reported at FINAL)
#           FINAL  always, when a cycle is open
#           Crash in FIX or FINAL -> immediate email
#           Failure / manual-lookup emails also go to $AlertTo.
#
#  One domain failing (e.g. DNS write refused) is recorded as Failed and the run
#  carries on; CHECK retries it, FINAL reports it. Exit code 1 when anything failed.
#  Going live = the SETTINGS block only ($Allowlist = @(), $AlertTo = the DL).
#
#  Safety (carried over from Invoke-AfdRevalidation.ps1, proven Aug 2026):
#    - every lookup is resolved BEFORE any change; a bad lookup fails harmlessly
#    - never trusts the regenerate call's status; polls until the token CHANGES
#    - token never changes -> domain skipped, DNS untouched
#    - _dnsauth is replaced in ONE PUT (never empty) with If-Match on its etag
#    - "Approved" is not success; only the SECRET's expirationDate moving is
#
#  Windows PowerShell 5.1 on the Jenkins server (cert JWT auth, ARM REST, no az CLI).
#
#  Local testing:  -UseAzCliToken -DryRun  (your az login, read-only, no email,
#                  no state written; email preview saved as HTML next to the script)
# =====================================================================================

[CmdletBinding()]
param(
    [ValidateSet('Auto','Fix','Check','Final')][string]$Mode = 'Auto',
    [switch]$DryRun,
    [switch]$UseAzCliToken,
    [int]$ThresholdDays = 21,    # override only for dry-run testing
    [string[]]$TestAllowlist     # override only for dry-run testing
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================ SETTINGS - the only lines to edit ======================

# Domains the job may change. @() = every eligible apex domain (production).
# While this has entries, anything else that is due is reported as "WouldFix" and left alone.
$Allowlist = @()

# Never changed, even when due and eligible. Reported as Manual so a person renews it.
$Exclude   = @()

# Every email goes to $To. Failure / manual-lookup emails ALSO go to $AlertTo.
$To        = @('you@example.com')
$AlertTo   = @('alerts@example.com')

# Freshservice: open ONE Pre-approved change when a Monday run is about to renew certificates.
# $false = no change is opened. $true needs the key file below on this server (DPAPI file made
# by the account Jenkins runs as, holding a 'Freshservice' entry). A Freshservice problem never
# stops a renewal: it is logged and shown as a note in the Tuesday report.
$CreateChange = $true
$FreshKeyFile = 'D:\Scripts\AFD-Certificate-Auto-Revalidation\freshservice-key.bin'

# =====================================================================================

$SubscriptionId = 'YOUR_SUBSCRIPTION_ID'
if ($ThresholdDays -ne 21 -and -not $DryRun) { throw "-ThresholdDays can only be changed with -DryRun" }

$Allowlist = @($Allowlist | ForEach-Object { $_.ToLower() })
$Exclude   = @($Exclude   | ForEach-Object { $_.ToLower() })
if ($TestAllowlist) {
    if (-not $DryRun) { throw "-TestAllowlist can only be used with -DryRun" }
    $Allowlist = @($TestAllowlist | ForEach-Object { $_.ToLower() })
}

# Validation states Microsoft says to fix with Regenerate + new TXT.
# Rejected / InternalError / Approved-but-expiring are reported for a human instead.
$FixableStates = @('PendingRevalidation', 'Pending', 'Timeout')

$Profiles = @(
    @{ rg = 'RG-FRONTDOOR-A';      name = 'frontdoor-profile-a' },
    @{ rg = 'RG-FRONTDOOR-B'; name = 'frontdoor-profile-b'   },
    @{ rg = 'RG-FRONTDOOR-C';                   name = 'frontdoor-profile-c'    }
)

$From       = 'jenkins@example.com'
$SmtpServer = 'smtp.example.com'

# Service principal your-automation-app (same as the monitor)
$AppId      = 'YOUR_APP_CLIENT_ID'
$TenantId   = 'YOUR_TENANT_ID'
$Thumbprint = 'YOUR_CERT_THUMBPRINT'

$CdnApi = '2024-02-01'
$DnsApi = '2018-05-01'

# Freshservice change defaults (Change Type 7 = Pre-approved, Group = Infrastructure, no agent)
$FreshDomain  = 'YOUR_DOMAIN.freshservice.com'
$FreshRequester = YOUR_AGENT_ID          
$FreshAgentId   = YOUR_AGENT_ID           (the API key cannot look agents up, so this is fixed)
$FreshGroupId   = YOUR_GROUP_ID          # Infrastructure

$StateFile  = Join-Path $PSScriptRoot 'AutoRevalidation-State.json'
$HistoryDir = Join-Path $PSScriptRoot 'History'

# ============================ SETUP ==================================================

$RunDate = Get-Date
$BuildNo = if ($env:BUILD_NUMBER) { "build $($env:BUILD_NUMBER)" } else { "manual run" }
$script:ArmToken     = $null
$script:ArmTokenTime = $null
$script:State        = $null
$script:ExitCode     = 0

function Write-Step { param([string]$m) Write-Host "    $m" }

# ============================ HELPERS ================================================

function Get-ArmToken {
    if ($UseAzCliToken) {
        $t = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
        if (-not $t) { throw "az account get-access-token returned nothing - run az login" }
        return $t
    }

    # Same cert-JWT flow as AFD-Certificate-Expiry-Monitor
    $cert = Get-ChildItem Cert:\LocalMachine\My\ | Where-Object { $_.Thumbprint -eq $Thumbprint }
    if (-not $cert) { throw "Certificate not found. Thumbprint: $Thumbprint" }

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
        scope                 = "https://management.azure.com/.default"
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion      = "$headerB64.$payloadB64.$signature"
        grant_type            = "client_credentials"
    }
    $token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $tokenBody
    return $token.access_token
}

function Invoke-Arm {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [hashtable]$ExtraHeaders,
        [switch]$Allow404
    )
    # Tokens last ~60-90 min; a big fix week (many domains + approval waits) can outlast one.
    if (-not $script:ArmToken -or ((Get-Date) - $script:ArmTokenTime).TotalMinutes -gt 40) {
        $script:ArmToken     = Get-ArmToken
        $script:ArmTokenTime = Get-Date
    }
    $uri = if ($Path -like 'https://*') { $Path } else { "https://management.azure.com$Path" }
    $h = @{ Authorization = "Bearer $script:ArmToken" }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }

    $p = @{ Uri = $uri; Method = $Method; Headers = $h; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $p.Body        = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        $p.ContentType = 'application/json'
    }

    try {
        Invoke-RestMethod @p
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($Allow404 -and $code -eq 404) { return $null }
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw ("{0} {1} failed (HTTP {2}): {3}" -f $Method, ($uri -replace '\?.*$', ''), $code, $detail)
    }
}

function Get-ArmList {
    param([Parameter(Mandatory)][string]$Path)
    $out  = @()
    $next = $Path
    while ($next) {
        $r = Invoke-Arm -Path $next
        if ($r.value) { $out += @($r.value) }
        $next = $r.nextLink
    }
    return $out
}

# PS 5.1 leaves ISO dates as strings, PS 7 turns them into DateTime. Normalise to UTC.
function ConvertTo-UtcDate {
    param($v)
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }
        return $v.ToUniversalTime()
    }
    return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal')
}

function Format-Date { param($d) if ($d) { (ConvertTo-UtcDate $d).ToString('yyyy-MM-dd') } else { '' } }

function Get-ProfilePath { param($rg, $name) "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.Cdn/profiles/$name" }

# --- AFD reads --------------------------------------------------------------------

# Every custom domain on all 3 profiles, with its secret's real expiry.
function Get-AfdInventory {
    $inv = @{}
    foreach ($p in $Profiles) {
        $base = Get-ProfilePath $p.rg $p.name

        $secretExp = @{}
        foreach ($s in (Get-ArmList "$base/secrets?api-version=$CdnApi")) {
            $secretExp[$s.name.ToLower()] = ConvertTo-UtcDate $s.properties.parameters.expirationDate
        }

        foreach ($cd in (Get-ArmList "$base/customDomains?api-version=$CdnApi")) {
            $host_ = $cd.properties.hostName.ToLower()
            if ($inv.ContainsKey($host_)) { continue }
            $secretName = $null
            if ($cd.properties.tlsSettings.secret.id) { $secretName = ($cd.properties.tlsSettings.secret.id -split '/')[-1].ToLower() }
            $exp = if ($secretName -and $secretExp.ContainsKey($secretName)) { $secretExp[$secretName] } else { $null }
            $inv[$host_] = [pscustomobject]@{
                Domain    = $host_
                Profile   = $p.name
                ProfileRg = $p.rg
                CdName    = $cd.name
                State     = $cd.properties.domainValidationState
                Token     = $cd.properties.validationProperties.validationToken
                CertType  = $cd.properties.tlsSettings.certificateType
                Expiry    = $exp
                DaysLeft  = if ($exp) { [math]::Round(($exp - [datetime]::UtcNow).TotalDays, 1) } else { $null }
            }
        }
    }
    return $inv
}

function Get-CustomDomain {
    param($d)
    Invoke-Arm -Path ("{0}/customDomains/{1}?api-version={2}" -f (Get-ProfilePath $d.ProfileRg $d.Profile), $d.CdName, $CdnApi)
}

# Current secret expiry for one domain (re-reads the custom domain so a changed
# secret id is still followed).
function Get-CurrentExpiry {
    param($d)
    $cd = Get-CustomDomain $d
    $sid = $cd.properties.tlsSettings.secret.id
    if (-not $sid) { return @{ Expiry = $null; State = $cd.properties.domainValidationState; Token = $cd.properties.validationProperties.validationToken } }
    $sec = Invoke-Arm -Path ("{0}?api-version={1}" -f $sid, $CdnApi)
    return @{
        Expiry = ConvertTo-UtcDate $sec.properties.parameters.expirationDate
        State  = $cd.properties.domainValidationState
        Token  = $cd.properties.validationProperties.validationToken
    }
}

# --- DNS reads / writes --------------------------------------------------------------

function Get-DnsZones {
    $z = @{}
    foreach ($zone in (Get-ArmList "/subscriptions/$SubscriptionId/providers/Microsoft.Network/dnszones?api-version=$DnsApi")) {
        $z[$zone.name.ToLower()] = $zone.id
    }
    return $z
}

function Get-DnsAuth {
    param([string]$ZoneId)
    Invoke-Arm -Path "$ZoneId/TXT/_dnsauth?api-version=$DnsApi" -Allow404
}

function Get-TxtValues {
    param($rs)
    if (-not $rs) { return @() }
    return @($rs.properties.TXTRecords | ForEach-Object { ($_.value -join '') })
}

# CAA at the apex that does not allow DigiCert would block issuance.
function Test-CaaBlocksDigiCert {
    param([string]$ZoneId)
    $caa = Invoke-Arm -Path "$ZoneId/CAA/@?api-version=$DnsApi" -Allow404
    if (-not $caa) { return $false }
    $issuers = @($caa.properties.caaRecords | Where-Object { $_.tag -in 'issue', 'issuewild' } | ForEach-Object { $_.value })
    if ($issuers.Count -eq 0) { return $false }
    return -not ($issuers | Where-Object { $_ -match 'digicert\.com' })
}

# Replace _dnsauth with the new token in ONE PUT (the set is never empty), TTL 60.
# If-Match on the etag so a change made by someone else in between is not overwritten.
function Set-DnsAuth {
    param([string]$ZoneId, $Existing, [string]$Token)
    $props = @{ TTL = 60; TXTRecords = @(@{ value = @($Token) }) }
    if ($Existing.properties.metadata) { $props.metadata = $Existing.properties.metadata }
    Invoke-Arm -Method PUT -Path "$ZoneId/TXT/_dnsauth?api-version=$DnsApi" `
        -Body @{ properties = $props } -ExtraHeaders @{ 'If-Match' = $Existing.etag } | Out-Null
}

# --- Live check (informational only; Zscaler can mask results on some networks) ---

function Get-LiveStatus {
    param([string]$Domain)
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://$Domain/")
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 20000
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        $certExp = ''
        if ($req.ServicePoint.Certificate) {
            $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $req.ServicePoint.Certificate
            $certExp = $c2.NotAfter.ToString('yyyy-MM-dd')
        }
        return "HTTP $code, served cert to $certExp"
    }
    catch {
        return "check failed: $($_.Exception.Message)"
    }
}

# --- State file -----------------------------------------------------------------------

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    return ([IO.File]::ReadAllText($StateFile) | ConvertFrom-Json)
}

function Save-State {
    if ($DryRun -or -not $script:State) { return }
    $json = $script:State | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($StateFile, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Close-Cycle {
    if ($DryRun -or -not (Test-Path $StateFile)) { return }
    if (-not (Test-Path $HistoryDir)) { New-Item -ItemType Directory -Path $HistoryDir | Out-Null }
    $id = if ($script:State -and $script:State.CycleId) { $script:State.CycleId } else { (Get-Date -Format 'yyyy-MM-dd_HHmm') }
    Move-Item -Path $StateFile -Destination (Join-Path $HistoryDir "Cycle-$id.json") -Force
}

function Add-StateError {
    param([string]$RunMode, [string]$Message)
    $err = [pscustomobject]@{ Run = $RunMode; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Message = $Message }
    if (-not $script:State) { $script:State = Read-State }
    if (-not $script:State) { return $false }
    $script:State.Errors = @($script:State.Errors) + $err
    Save-State
    return $true
}

# --- Freshservice change -------------------------------------------------------------
# Never throws. Returns the change number, or $null when it was not opened.
function New-RenewalChange {
    param([Parameter(Mandatory)][object[]]$Domains, [string]$SubjectPrefix = '')
    try {
        if (-not (Test-Path $FreshKeyFile)) { throw "Freshservice key file not found: $FreshKeyFile" }
        # Machine-scope DPAPI blob (any process on this server can decrypt it; the file's NTFS ACL limits who can read it)
        Add-Type -AssemblyName System.Security
        $key = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($FreshKeyFile), $null, 'LocalMachine'))
        if (-not $key) { throw "Freshservice key file is empty" }
        $auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${key}:X")); 'Content-Type' = 'application/json' }

        $fmt   = 'yyyy-MM-ddTHH:mm:ssZ'
        $start = (Get-Date).ToUniversalTime().AddMinutes(2)
        $list  = ($Domains | ForEach-Object { "<li>$(HtmlEnc $_.Domain) - $([math]::Floor($_.DaysLeft)) days left (expires $(Format-Date $_.OldExpiry))</li>" }) -join ''
        $desc  = "<div>The weekly AFD auto revalidation job found $($Domains.Count) Front Door certificate(s) at $ThresholdDays days or less and is renewing them now.</div><ul>$list</ul>"
        $body  = @{
            workspace_id       = 2
            requester_id       = $FreshRequester
            agent_id           = $FreshAgentId
            group_id           = $FreshGroupId
            subject            = "$SubjectPrefix" + "AFD certificate auto revalidation - $($Domains.Count) domain(s) - $($RunDate.ToString('yyyy-MM-dd'))"
            description        = $desc
            change_type        = 7
            status             = 1
            priority           = 1
            impact             = 1
            risk               = 1
            planned_start_date = $start.ToString($fmt)
            planned_end_date   = $start.AddHours(14).ToString($fmt)
            custom_fields      = @{ systems_impacted = 'Azure Resource'; change_tested = 'Yes' }
            planning_fields    = @{
                reason_for_change = @{ description = 'Front Door apex managed certificates do not renew on their own. Weekly automated revalidation keeps them valid.' }
                change_impact     = @{ description = 'None expected. Certificate renewal only. No downtime, no change to site content.' }
                rollout_plan      = @{ description = '<div>1. Job refreshes the validation token for each certificate due within 21 days.</div><div>2. Job updates the _dnsauth TXT record.</div><div>3. Next day the job confirms the certificate expiry date moved.</div>' }
                backout_plan      = @{ description = 'Renew by hand.' }
            }
        } | ConvertTo-Json -Depth 6

        $base = "https://$FreshDomain/api/v2/changes"
        $created = Invoke-RestMethod -Uri $base -Headers $auth -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body))
        $id = $created.change.id
        try { Invoke-RestMethod -Uri "$base/$id" -Headers $auth -Method Put -Body ([Text.Encoding]::UTF8.GetBytes((@{ status = 2 } | ConvertTo-Json))) | Out-Null } catch { Write-Host "  (CHN-$id opened, but could not move it to Planning: $($_.Exception.Message))" }
        Write-Host "  Opened Freshservice change CHN-$id"
        return $id
    }
    catch {
        $m = "Freshservice change not opened: $($_.Exception.Message)"
        Write-Host "  WARNING - $m (renewal continues)"
        try { [void](Add-StateError -RunMode 'Fix' -Message $m) } catch { }
        return $null
    }
}

# Tuesday result -> the CR opened on Monday. Never throws; a problem here only becomes a note in the report.
# Freshservice stateflow: Pending Release (4) -> Pending Review (5) -> Closed (6). Closing needs no extra fields,
# change_result_explanation is the result text. All renewed = Closed; anything failed = note + left at Pending Review.
function Close-RenewalChange {
    param([Parameter(Mandatory)]$ChangeId, [AllowEmptyCollection()][object[]]$Renewed = @(), [AllowEmptyCollection()][object[]]$Failed = @())
    try {
        if (-not (Test-Path $FreshKeyFile)) { throw "Freshservice key file not found: $FreshKeyFile" }
        Add-Type -AssemblyName System.Security
        $key = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($FreshKeyFile), $null, 'LocalMachine'))
        if (-not $key) { throw "Freshservice key file is empty" }
        $auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${key}:X")); 'Content-Type' = 'application/json' }
        $base = "https://$FreshDomain/api/v2/changes/$ChangeId"
        $put  = { param($o) Invoke-RestMethod -Uri $base -Headers $auth -Method Put -Body ([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Depth 5))) | Out-Null }

        $okList   = ($Renewed | ForEach-Object { "<li>$(HtmlEnc $_.Domain) - renewed, new expiry $(Format-Date $_.NewExpiry)</li>" }) -join ''
        $failList = ($Failed  | ForEach-Object { "<li>$(HtmlEnc $_.Domain) - NOT renewed ($(HtmlEnc $_.Status))</li>" }) -join ''
        $noteHtml = "<div>Tuesday result from the AFD auto revalidation job: $($Renewed.Count) renewed, $($Failed.Count) not renewed.</div>"
        if ($okList)   { $noteHtml += "<ul>$okList</ul>" }
        if ($failList) { $noteHtml += "<div>Needs a manual look:</div><ul>$failList</ul>" }
        Invoke-RestMethod -Uri "$base/notes" -Headers $auth -Method Post -Body ([Text.Encoding]::UTF8.GetBytes((@{ body = $noteHtml } | ConvertTo-Json))) | Out-Null

        & $put @{ status = 5 }                                   # Pending Review
        if ($Failed.Count -eq 0) {
            & $put @{ status = 6; custom_fields = @{ change_result_explanation = "All $($Renewed.Count) certificate(s) renewed." } }   # Closed
            Write-Host "  Closed Freshservice change CHN-$ChangeId"
        }
        else {
            Write-Host "  CHN-$ChangeId left at Pending Review: $($Failed.Count) domain(s) not renewed (note added)"
        }
    }
    catch {
        $m = "Freshservice change CHN-$ChangeId not updated: $($_.Exception.Message)"
        Write-Host "  WARNING - $m"
        try { [void](Add-StateError -RunMode 'Final' -Message $m) } catch { }
    }
}

# --- Email ---------------------------------------------------------------------------

function HtmlEnc { param([string]$s) if ($null -eq $s) { return '' } [System.Net.WebUtility]::HtmlEncode($s) }

# $Rows: objects with the properties named in $Columns
function Send-Report {
    param(
        [string]$Subject,
        [string]$Title,
        [string]$IntroHtml,
        [string]$IntroPlain,
        $Rows,
        [string[]]$Columns,
        [string]$NoteHtml = '',
        [string]$NotePlain = '',
        [switch]$Alert              # failure / manual lookup: also goes to $AlertTo
    )

    $th = ($Columns | ForEach-Object { "<th>$(HtmlEnc $_)</th>" }) -join ''
    $tr = (@($Rows) | ForEach-Object {
        $r = $_
        "<tr>" + (($Columns | ForEach-Object { "<td>$(HtmlEnc ([string]$r.$_))</td>" }) -join '') + "</tr>"
    }) -join "`n"
    $tableHtml = if (@($Rows).Count) { "<table class='data'><tr>$th</tr>`n$tr</table>" } else { '' }

    $plainRows = (@($Rows) | ForEach-Object {
        $r = $_
        "  - " + (($Columns | ForEach-Object { "$($_): $($r.$_)" }) -join ' | ')
    }) -join "`n"

    $mode = if ($DryRun) { ' [DRY RUN - no changes made]' } else { '' }
    $scope = if ($Allowlist.Count) { "Allowlist: $($Allowlist -join ', ')" } else { 'Scope: all eligible apex domains' }
    if ($Exclude.Count) { $scope += ". Excluded: $($Exclude -join ', ')" }
    $foot = "Generated by Jenkins job <strong>AFD-Certificate-Auto-Revalidation</strong>, $BuildNo, $($script:RunMode) run $($RunDate.ToString('d MMM yyyy HH:mm'))$mode.<br>$(HtmlEnc $scope). Threshold: $ThresholdDays days."
    $footPlain = "Generated by Jenkins job AFD-Certificate-Auto-Revalidation, $BuildNo, $($script:RunMode) run $($RunDate.ToString('d MMM yyyy HH:mm'))$mode. $scope. Threshold: $ThresholdDays days."
    $recipients = @(@($To) + $(if ($Alert) { @($AlertTo) } else { @() }) | Where-Object { $_ } | Select-Object -Unique)
    $noteBlock = if ($NoteHtml) { "<div class='note'>$NoteHtml</div>" } else { '' }

    $html = @"
<html><head><meta charset='utf-8'>
<meta name='color-scheme' content='light only'>
<meta name='supported-color-schemes' content='light only'>
<style>
:root {color-scheme: light only; supported-color-schemes: light only;}
body {font-family: Calibri, 'Segoe UI', Arial, sans-serif; font-size: 11pt; color:#1f1f1f; margin:0;}
.band {background:#1c5cab; color:#fff; padding:14px 22px;}
.band .t {font-size:15pt; font-weight:600;}
.band .s {font-size:9.5pt; opacity:.9; margin-top:2px;}
.body {padding: 18px 22px 4px 22px;}
/* Mid-tone greys only - Outlook dark mode inverts light greys (see monitor build 3). */
table.data {border-collapse:collapse; width:100%; font-size:10.5pt; margin:12px 0; border:1px solid #7f7f7a;}
table.data th {background:#dcdcd6; border:1px solid #7f7f7a; padding:7px 10px; text-align:left; font-weight:600;}
table.data td {border:1px solid #7f7f7a; padding:7px 10px;}
.note {border-left:3px solid #eda100; background:#fdf6e6; padding:9px 12px; font-size:9.5pt; margin:6px 0 0 0;}
.foot {border-top:1px solid #7f7f7a; margin:20px 22px 0 22px; padding:10px 0 16px 0; font-size:8.5pt; color:#6d6d68;}
</style></head><body>
<div class='band'><div class='t'>$(HtmlEnc $Title)</div>
<div class='s'>Automated renewal &middot; Azure Front Door apex certificates</div></div>
<div class='body'>
$IntroHtml
$tableHtml
$noteBlock
</div>
<div class='foot'>$foot</div>
</body></html>
"@

    $plain = "$Title`n`n$IntroPlain`n`n$plainRows`n`n$NotePlain`n`n$footPlain"

    if ($DryRun) {
        $preview = Join-Path $PSScriptRoot ("Preview-{0}.html" -f $script:RunMode)
        [IO.File]::WriteAllText($preview, $html, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ""
        Write-Host "DRY RUN - email NOT sent. Subject: $Subject"
        Write-Host "Would go to: $($recipients -join ', ')"
        Write-Host "Preview saved: $preview"
        return
    }

    $mail = New-Object System.Net.Mail.MailMessage
    $mail.From = New-Object System.Net.Mail.MailAddress($From)
    foreach ($t in $recipients) { $mail.To.Add($t) }
    $mail.Subject = $Subject
    $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
    # multipart/alternative - Send-MailMessage -BodyAsHtml gets downgraded by the relay
    $mail.AlternateViews.Add([System.Net.Mail.AlternateView]::CreateAlternateViewFromString($plain, [System.Text.Encoding]::UTF8, 'text/plain'))
    $mail.AlternateViews.Add([System.Net.Mail.AlternateView]::CreateAlternateViewFromString($html, [System.Text.Encoding]::UTF8, 'text/html'))
    (New-Object System.Net.Mail.SmtpClient($SmtpServer)).Send($mail)
    Write-Host "Email sent to: $($recipients -join ', ')"
}

# ============================ CORE: FIX ONE DOMAIN ===================================
# Regenerate -> poll token until it changes -> replace _dnsauth. Updates $d in place
# and saves state after every domain, so a crash mid-run leaves an accurate record.

function Invoke-DomainFix {
    param($d)

    $before = Get-CustomDomain $d
    $oldToken = $before.properties.validationProperties.validationToken

    try {
        Invoke-Arm -Method POST -Path ("{0}/customDomains/{1}/refreshValidationToken?api-version={2}" -f `
            (Get-ProfilePath $d.ProfileRg $d.Profile), $d.CdName, $CdnApi) -Body '{}' | Out-Null
    }
    catch {
        # Spurious Not Found / BadRequest seen in Aug 2026 while it still worked - poll anyway
        Write-Step "regenerate reported an error (often spurious) - polling anyway: $($_.Exception.Message)"
    }

    $newToken = $null
    for ($i = 1; $i -le 24; $i++) {
        Start-Sleep -Seconds 5
        $t = (Get-CustomDomain $d).properties.validationProperties.validationToken
        if ($t -and $t -ne $oldToken) { $newToken = $t; break }
    }

    $d.Attempts   = [int]$d.Attempts + 1
    $d.LastAction = (Get-Date).ToString('yyyy-MM-dd HH:mm')

    if (-not $newToken) {
        $d.Status = 'Skipped'
        $d.Note   = 'Token never changed - DNS untouched'
        Write-Step $d.Note
        Save-State
        return
    }

    $rs = Get-DnsAuth $d.ZoneId
    if (-not $rs) {
        $d.Status = 'Manual'
        $d.Note   = '_dnsauth record disappeared after pre-flight - DNS untouched'
        Write-Step $d.Note
        Save-State
        return
    }
    $d.OldTxt   = (Get-TxtValues $rs) -join ', '
    $d.NewToken = $newToken      # recorded first, so a failed PUT still reports the value to set by hand

    Set-DnsAuth -ZoneId $d.ZoneId -Existing $rs -Token $newToken

    $d.Status   = 'Swapped'
    $d.Note     = ''
    Write-Step "new token $newToken - _dnsauth replaced, TTL 60"
    Save-State
}

# One domain's failure (e.g. DNS write refused) must not stop the others.
function Invoke-DomainFixSafe {
    param($d)
    try {
        Invoke-DomainFix $d
    }
    catch {
        $d.Status     = 'Failed'
        $d.Note       = "Error: $($_.Exception.Message)"
        $d.LastAction = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Write-Step "FAILED - $($_.Exception.Message)"
        $script:ExitCode = 1
        Save-State
    }
}

# Shared polling loop for Approved (the ~5 min waits overlap instead of stacking).
function Wait-ForApproval {
    param($items, [int]$Rounds = 45)
    $items = @($items)
    if ($items.Count -eq 0) { return }
    Write-Host ""
    Write-Host ("Polling {0} domain(s) for Approved (up to {1} min)..." -f $items.Count, [math]::Round($Rounds * 20 / 60))
    $start = Get-Date
    for ($r = 1; $r -le $Rounds; $r++) {
        Start-Sleep -Seconds 20
        $waiting = @($items | Where-Object { $_.StateNow -ne 'Approved' })
        if ($waiting.Count -eq 0) { break }
        foreach ($w in $waiting) {
            $w.StateNow = (Get-CustomDomain $w).properties.domainValidationState
            if ($w.StateNow -eq 'Approved') {
                Write-Step ("APPROVED {0} (+{1} min)" -f $w.Domain, [math]::Round(((Get-Date) - $start).TotalMinutes, 1))
            }
        }
    }
    Save-State
}

# ============================ MODES ==================================================

function Invoke-FixMode {
    Write-Host "Reading AFD custom domains, certificate secrets and DNS zones..."
    $inv   = Get-AfdInventory
    $zones = Get-DnsZones

    $due = @($inv.Values | Where-Object { $null -ne $_.DaysLeft -and $_.DaysLeft -le $ThresholdDays } | Sort-Object DaysLeft)
    Write-Host ("{0} custom domains read; {1} with a cert at {2} days or less." -f $inv.Count, $due.Count, $ThresholdDays)

    # A cycle left open from last week (FINAL never ran) is archived and flagged.
    $staleNote = ''
    $existing = Read-State
    if ($existing) {
        $staleNote = "Previous cycle $($existing.CycleId) was never finalised (stage: $($existing.Stage)). It has been archived to History."
        Write-Host $staleNote
        $script:State = $existing
        Close-Cycle
        $script:State = $null
    }

    if ($due.Count -eq 0) {
        Write-Host "Nothing due. No email."
        if ($staleNote) {
            Send-Report -Subject 'AFD Auto Revalidation - previous cycle not finalised' -Title 'AFD Auto Revalidation' `
                -IntroHtml "<p>$(HtmlEnc $staleNote)</p><p>Nothing is due this week.</p>" -IntroPlain "$staleNote`nNothing is due this week." -Rows @() -Columns @()
        }
        return
    }

    # ---------------- PRE-FLIGHT: classify everything before changing anything --------
    $work = @()
    foreach ($x in $due) {
        $d = [pscustomobject]@{
            Domain = $x.Domain; Profile = $x.Profile; ProfileRg = $x.ProfileRg; CdName = $x.CdName
            ZoneId = $null; OldExpiry = $x.Expiry.ToString('o'); NewExpiry = ''; DaysLeft = $x.DaysLeft
            StateBefore = $x.State; StateNow = $x.State; OldToken = $x.Token; NewToken = ''; OldTxt = ''
            Attempts = 0; LastAction = ''; Status = ''; Note = ''; Live = ''
        }
        $zoneId = if ($zones.ContainsKey($x.Domain)) { $zones[$x.Domain] } else { $null }

        if ($Exclude -contains $x.Domain) {
            $d.Status = 'Manual'; $d.Note = 'Excluded in the script settings - renew by hand'
        }
        elseif ($Allowlist.Count -and ($Allowlist -notcontains $x.Domain)) {
            $d.Status = 'WouldFix'; $d.Note = 'Not in test allowlist - not changed'
        }
        elseif (-not $zoneId) {
            $d.Status = 'Manual'; $d.Note = 'Not an apex domain in Azure DNS (subdomain, or DNS hosted elsewhere)'
        }
        elseif ($x.CertType -ne 'ManagedCertificate') {
            $d.Status = 'Manual'; $d.Note = "Certificate type is $($x.CertType), not Azure-managed"
        }
        elseif ($FixableStates -notcontains $x.State) {
            $d.Status = 'Manual'
            $d.Note = if ($x.State -eq 'Approved') { 'Approved but the cert has not renewed - Azure has not asked for revalidation' } else { "Validation state $($x.State) - needs a person" }
        }
        else {
            $d.ZoneId = $zoneId
            $rs = Get-DnsAuth $zoneId
            if (-not $rs) {
                $d.Status = 'Manual'; $d.Note = 'No _dnsauth record in the zone (the job can only edit an existing one)'
            }
            elseif (Test-CaaBlocksDigiCert $zoneId) {
                $d.Status = 'Manual'; $d.Note = 'CAA record does not allow DigiCert - issuance would be rejected'
            }
            else {
                $d.OldTxt = (Get-TxtValues $rs) -join ', '
                $d.Status = 'Ready'
            }
        }
        $work += $d
    }

    Write-Host ""
    Write-Host "PRE-FLIGHT:"
    $work | Format-Table Domain, Profile, DaysLeft, StateBefore, Status, Note -AutoSize | Out-String -Width 250 | Write-Host

    $ready = @($work | Where-Object { $_.Status -eq 'Ready' })

    if ($DryRun) {
        foreach ($d in $ready) { $d.Status = 'DryRun'; $d.Note = "Would regenerate token (now '$($d.OldToken)') and replace _dnsauth ('$($d.OldTxt)')" }
    }
    elseif ($ready.Count) {
        $script:State = [pscustomobject]@{
            CycleId = (Get-Date -Format 'yyyy-MM-dd_HHmm'); Started = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            Stage = 'Fixing'; Domains = $work; Errors = @()
        }
        Save-State

        if ($CreateChange) {
            $chn = New-RenewalChange -Domains $ready
            if ($chn) { $script:State | Add-Member -NotePropertyName ChangeId -NotePropertyValue $chn -Force; Save-State }
        }

        Write-Host ("FIX - {0} domain(s)" -f $ready.Count)
        foreach ($d in $ready) {
            Write-Host ""
            Write-Host "  $($d.Domain)"
            Invoke-DomainFixSafe $d
        }
        Wait-ForApproval @($ready | Where-Object { $_.Status -eq 'Swapped' })
        foreach ($d in $ready) { $d.Live = Get-LiveStatus $d.Domain }
        $script:State.Stage = 'Fixed'
        Save-State
    }

    # ---------------- Monday email (only reached when something is due) ---------------
    $rows = $work | ForEach-Object {
        [pscustomobject]@{
            Domain = $_.Domain; 'Days left' = [math]::Floor($_.DaysLeft); Expires = (Format-Date $_.OldExpiry)
            Result = $_.Status; Validation = $_.StateNow; Note = $_.Note
        }
    }
    $swapped = @($work | Where-Object { $_.Status -eq 'Swapped' })
    $failedN = @($work | Where-Object { $_.Status -in 'Failed', 'Skipped' })
    $manualN = @($work | Where-Object { $_.Status -eq 'Manual' })
    $intro = "<p>$($due.Count) certificate(s) at $ThresholdDays days or less. $($swapped.Count) renewal(s) started tonight.</p>"
    if ($failedN.Count) { $intro += "<p><strong>$($failedN.Count) could not be started</strong> - the 03:00 run retries them; the 09:00 report gives the final answer.</p>" }
    if ($staleNote) { $intro = "<p><strong>$(HtmlEnc $staleNote)</strong></p>" + $intro }
    $note  = if ($swapped.Count -or $failedN.Count -or $DryRun) {
        '<strong>Expect the Tuesday 09:00 report.</strong> If it has not arrived by about 09:15, the job did not run - check Jenkins.'
    } else { 'Nothing was changed. Items marked Manual need a person.' }
    if ($manualN.Count -and ($swapped.Count -or $failedN.Count)) { $note += ' Items marked Manual were not touched and need a person.' }

    $subject = "AFD Auto Revalidation - $($swapped.Count) started, $($due.Count) due"
    if ($failedN.Count) { $subject += ", $($failedN.Count) failed" }
    Send-Report -Subject $subject `
        -Title 'AFD Auto Revalidation - Monday fix' -IntroHtml $intro -IntroPlain ($intro -replace '</p><p>', "`n" -replace '<[^>]+>', '') `
        -Rows $rows -Columns @('Domain', 'Days left', 'Expires', 'Result', 'Validation', 'Note') `
        -NoteHtml $note -NotePlain ($note -replace '<[^>]+>', '') -Alert:([bool]($failedN.Count -or $manualN.Count))
}

# Re-reads every domain the cycle touched. Renewed = secret expiry moved forward.
function Update-RenewalStatus {
    # Monday run stopped before reaching these - treat as failed so they are retried/reported.
    foreach ($d in @($script:State.Domains | Where-Object { $_.Status -eq 'Ready' })) {
        $d.Status = 'Failed'; $d.Note = 'Monday fix run stopped before this domain was done'
    }
    foreach ($d in @($script:State.Domains | Where-Object { $_.Status -in 'Swapped', 'Skipped', 'Failed', 'ApprovedNotRenewed' })) {
        $cur = Get-CurrentExpiry $d
        $d.StateNow = $cur.State
        $old = ConvertTo-UtcDate $d.OldExpiry
        if ($cur.Expiry -and $old -and $cur.Expiry -gt $old.AddDays(1)) {
            $d.Status    = 'Renewed'
            $d.NewExpiry = $cur.Expiry.ToString('o')
            $d.Note      = ''
        }
        elseif ($cur.State -eq 'Approved') {
            $d.Status = 'ApprovedNotRenewed'
            $d.Note   = 'Approved but the cert has not renewed yet'
        }
        $d.Live = Get-LiveStatus $d.Domain
    }
    Save-State
}

function Invoke-CheckMode {
    $script:State = Read-State
    # 'Fixing' = the Monday run crashed part-way; still check/retry what it started.
    if (-not $script:State -or $script:State.Stage -notin 'Fixed', 'Fixing') {
        Write-Host "No open cycle waiting for a check. Nothing to do."
        return
    }
    if ($script:State.Stage -eq 'Fixing') { $script:State | Add-Member -NotePropertyName FixIncomplete -NotePropertyValue $true -Force }

    Update-RenewalStatus

    # Retry ONLY when not Approved and not renewed. Approved-but-not-renewed is left
    # alone: regenerating then could interrupt an issuance already in progress.
    $retry = @($script:State.Domains | Where-Object {
        $_.Status -in 'Swapped', 'Skipped', 'Failed' -and $FixableStates -contains $_.StateNow
    })
    Write-Host ("{0} renewed, {1} to retry." -f @($script:State.Domains | Where-Object Status -eq 'Renewed').Count, $retry.Count)

    if (-not $DryRun) {
        foreach ($d in $retry) {
            Write-Host ""
            Write-Host "  RETRY $($d.Domain)"
            Invoke-DomainFixSafe $d
        }
        Wait-ForApproval @($retry | Where-Object { $_.Status -eq 'Swapped' })
    }

    $script:State.Stage = 'Checked'
    Save-State
    $script:State.Domains | Format-Table Domain, Status, StateNow, Attempts, Note -AutoSize | Out-String -Width 250 | Write-Host
    # No email from this run, by design.
}

function Invoke-FinalMode {
    $script:State = Read-State
    if (-not $script:State -or $script:State.Stage -notin 'Fixed', 'Fixing', 'Checked') {
        Write-Host "No open cycle to finalise. Nothing to do."
        return
    }
    $missedCheck   = ($script:State.Stage -in 'Fixed', 'Fixing')
    $fixIncomplete = ($script:State.Stage -eq 'Fixing') -or ($script:State.PSObject.Properties['FixIncomplete'] -and $script:State.FixIncomplete)

    Update-RenewalStatus

    $acted   = @($script:State.Domains | Where-Object { $_.Status -notin 'WouldFix', 'Manual', 'DryRun', 'Ready' })
    $renewed = @($acted | Where-Object Status -eq 'Renewed')
    $failed  = @($acted | Where-Object Status -ne 'Renewed')

    $rows = foreach ($d in $acted) {
        $cur = if ($d.Status -ne 'Renewed') { (Get-TxtValues (Get-DnsAuth $d.ZoneId)) -join ', ' } else { '' }
        $label = switch ($d.Status) {
            'Renewed'            { 'Renewed' }
            'ApprovedNotRenewed' { 'Approved, cert not renewed' }
            'Swapped'            { 'Not validated' }
            'Skipped'            { 'Token never changed' }
            'Failed'             { 'Fix failed' }
            default              { $d.Status }
        }
        [pscustomobject]@{
            Domain      = $d.Domain
            Result      = $label
            'Old expiry'= Format-Date $d.OldExpiry
            'New expiry'= Format-Date $d.NewExpiry
            Attempts    = $d.Attempts
            Validation  = $d.StateNow
            'Detail'    = if ($d.Status -eq 'Renewed') { $d.Live } else { "Token: $($d.NewToken) | _dnsauth now: $cur | $($d.Note)" }
        }
    }

    # Report back on the change opened by Monday's run (if there was one)
    if ($CreateChange -and -not $DryRun -and $script:State.PSObject.Properties['ChangeId'] -and $script:State.ChangeId) {
        Close-RenewalChange -ChangeId $script:State.ChangeId -Renewed $renewed -Failed $failed
    }

    $notes = @()
    if ($fixIncomplete) { $notes += 'The Monday fix run stopped part-way (see the failure email it sent).' }
    if ($missedCheck)   { $notes += 'The 03:00 check/retry did not run.' }
    foreach ($e in @($script:State.Errors)) { if ($e) { $notes += "$($e.Run) run at $($e.Time) failed: $($e.Message)" } }

    if ($failed.Count) {
        $subject = "AFD Auto Revalidation - MANUAL LOOKUP NEEDED - $($failed.Count) not renewed"
        $intro   = "<p><strong>$($failed.Count) domain(s) did not renew</strong> and need a manual look. $($renewed.Count) renewed.</p>"
    }
    else {
        $subject = "AFD Auto Revalidation - all $($renewed.Count) renewed"
        $intro   = "<p>All $($renewed.Count) domain(s) renewed.</p>"
    }
    if ($notes.Count) { $intro += '<p>' + (($notes | ForEach-Object { HtmlEnc $_ }) -join '<br>') + '</p>' }

    $noteHtml = if ($failed.Count) { 'Fallback: run <code>Invoke-AfdRevalidation.ps1</code> manually for the domains above. Retrying a domain that is Approved but not renewed fixed both cases in Aug 2026.' } else { '' }

    Send-Report -Subject $subject -Title 'AFD Auto Revalidation - Tuesday result' `
        -IntroHtml $intro -IntroPlain ($intro -replace '<br>', "`n" -replace '<[^>]+>', '') `
        -Rows $rows -Columns @('Domain', 'Result', 'Old expiry', 'New expiry', 'Attempts', 'Validation', 'Detail') `
        -NoteHtml $noteHtml -NotePlain ($noteHtml -replace '<[^>]+>', '') -Alert:([bool]($failed.Count -or $notes.Count))
    if ($failed.Count) { $script:ExitCode = 1 }

    $script:State.Stage = 'Done'
    Save-State
    Close-Cycle
}

# ============================ MAIN ===================================================

$script:RunMode = $Mode
try {
    if ($Mode -eq 'Auto') {
        $h = $RunDate.Hour
        $script:RunMode =
            if     ($RunDate.DayOfWeek -eq 'Monday'  -and $h -ge 18)              { 'Fix' }
            elseif ($RunDate.DayOfWeek -eq 'Tuesday' -and $h -lt 6)               { 'Check' }
            elseif ($RunDate.DayOfWeek -eq 'Tuesday' -and $h -ge 6 -and $h -lt 12) { 'Final' }
            else { throw "Auto mode has no slot for $($RunDate.ToString('dddd HH:mm')). Pass -Mode Fix|Check|Final." }
    }

    Write-Host "AFD Certificate Auto Revalidation"
    Write-Host "  Run      : $($RunDate.ToString('yyyy-MM-dd HH:mm')) - $($script:RunMode)$(if ($DryRun) { ' [DRY RUN - NO CHANGES]' })"
    Write-Host "  Threshold: $ThresholdDays days   Allowlist: $(if ($Allowlist.Count) { $Allowlist -join ', ' } else { 'ALL' })   Excluded: $(if ($Exclude.Count) { $Exclude -join ', ' } else { 'none' })"
    Write-Host "  Email    : $($To -join ', ')   Alerts also to: $(if (@($AlertTo | Where-Object { $_ }).Count) { $AlertTo -join ', ' } else { 'nobody else' })"
    Write-Host ""

    $script:ArmToken     = Get-ArmToken
    $script:ArmTokenTime = Get-Date
    Write-Host "Authenticated to Azure Resource Manager."
    Write-Host ""

    switch ($script:RunMode) {
        'Fix'   { Invoke-FixMode }
        'Check' { Invoke-CheckMode }
        'Final' { Invoke-FinalMode }
    }
    if ($script:ExitCode) { Write-Host ""; Write-Host "Finished with domain failures (see above) - exit 1." }
    Exit $script:ExitCode
}
catch {
    $msg = $_.Exception.Message
    Write-Host ""
    Write-Host "FAILED ($($script:RunMode)): $msg"

    if ($script:RunMode -eq 'Check') {
        # No 3am email - the 09:00 run reports it.
        try { if (Add-StateError -RunMode 'Check' -Message $msg) { Write-Host "Error saved to state file for the 09:00 report." } } catch { }
    }
    else {
        try {
            $after = if ($script:RunMode -eq 'Fix' -and $script:State -and -not $DryRun) {
                ' Renewals already started are kept: the 03:00 run checks and retries them and the Tuesday 09:00 report gives the result.'
            } else { '' }
            Send-Report -Alert -Subject "AFD Auto Revalidation - JOB FAILED ($($script:RunMode))" -Title 'AFD Auto Revalidation - job failed' `
                -IntroHtml "<p>The <strong>$($script:RunMode)</strong> run failed:</p><p><code>$(HtmlEnc $msg)</code></p>" `
                -IntroPlain "The $($script:RunMode) run failed:`n$msg" -Rows @() -Columns @() `
                -NoteHtml "Check the Jenkins console log. State file: <code>AutoRevalidation-State.json</code> next to the script.$after" `
                -NotePlain "Check the Jenkins console log. State file: AutoRevalidation-State.json next to the script.$after"
        }
        catch { Write-Host "Could not send the failure email either: $($_.Exception.Message)" }
    }
    Exit 1
}
