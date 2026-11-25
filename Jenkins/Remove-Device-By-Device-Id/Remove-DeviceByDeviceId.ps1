# This PowerShell script is specifically tailored for running via Jenkins with Parameterized Builds.
# jenkins.example.com
# Removes devices from Intune and/or Entra using the shared Device ID (same ID on both platforms).
# Accepts multiple Device IDs (comma, semicolon, or newline separated).

$Date = $(Get-Date -format yyyy-MM-dd-HH-mm)

# ======================== VALIDATION ===========================

$GuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

$RemoveFrom = $($env:RemoveFrom)
If ($RemoveFrom -notin @("IntuneOnly", "EntraOnly", "Both")) {
    Write-Host "Invalid RemoveFrom value. Must be IntuneOnly, EntraOnly, or Both."
    Exit 1
}

# Parse multiple Device IDs — support comma, semicolon, newline separators
$RawDeviceIds = If ($env:DeviceIds) { $env:DeviceIds } ElseIf ($env:DeviceId) { $env:DeviceId } Else { "" }
$DeviceIds = $RawDeviceIds -split '[,;\r\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

If ($DeviceIds.Count -eq 0) {
    Write-Host "Please enter at least one Device ID."
    Exit 1
}

$invalidIds = $DeviceIds | Where-Object { $_ -notmatch $GuidPattern }
If ($invalidIds.Count -gt 0) {
    Write-Host "Invalid Device ID(s) — must be valid GUIDs:"
    $invalidIds | ForEach-Object { Write-Host "  - $_" }
    Exit 1
}

$IncPattern = "^#?INC-\d{4}\d+$"
$SrPattern  = "^#?SR-\d{4}\d+$"
$ChnPattern = "^#?CHN-\d{3}\d+$"

If (($($env:TicketNumber) -notmatch $IncPattern) -and ($($env:TicketNumber) -notmatch $SrPattern) -and ($($env:TicketNumber) -notmatch $ChnPattern)) {
    Write-Host "Please enter a valid ticket number"
    Exit 1
}

$env:TicketNumber = $($env:TicketNumber).Replace("#", "").ToUpper()

# ======================== LOGGING ==============================

$Log = "D:\JenkinsLogs\Remove-DeviceByDeviceId-Transcripts\$Date-$($env:TicketNumber)-Transcript.txt"
Start-Transcript -Path $Log -Append

Write-Host ""
Write-Host "Job Parameters:"
Write-Host "  Remove From:    $RemoveFrom"
Write-Host "  Device IDs:     $($DeviceIds.Count) submitted"
$DeviceIds | ForEach-Object { Write-Host "    - $_" }
Write-Host "  Ticket Number:  $($env:TicketNumber)"
Write-Host ""

# ======================== AUTHENTICATION =======================

$AppID    = "YOUR_APP_CLIENT_ID"
$TenantId = "YOUR_TENANT_ID"

$cert = Get-ChildItem Cert:\LocalMachine\My\ | Where-Object { $_.Thumbprint -eq "YOUR_CERT_THUMBPRINT" }

If (-not $cert) {
    Write-Host "Certificate not found. Thumbprint: YOUR_CERT_THUMBPRINT"
    Stop-Transcript
    Exit 1
}

$certHash   = [System.Convert]::ToBase64String($cert.GetCertHash())
$jwtHeader  = @{ alg = "RS256"; typ = "JWT"; x5t = $certHash } | ConvertTo-Json -Compress
$epoch      = [datetime]"1970-01-01T00:00:00Z"
$now        = [int]([datetime]::UtcNow - $epoch).TotalSeconds
$jwtPayload = @{
    aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    iss = $AppID
    sub = $AppID
    jti = [guid]::NewGuid().ToString()
    nbf = $now
    exp = $now + 600
} | ConvertTo-Json -Compress

$toBase64Url     = { param($bytes) [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
$headerB64       = & $toBase64Url ([System.Text.Encoding]::UTF8.GetBytes($jwtHeader))
$payloadB64      = & $toBase64Url ([System.Text.Encoding]::UTF8.GetBytes($jwtPayload))
$dataToSign      = [System.Text.Encoding]::UTF8.GetBytes("$headerB64.$payloadB64")
$rsa             = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
$signature       = & $toBase64Url ($rsa.SignData($dataToSign, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
$clientAssertion = "$headerB64.$payloadB64.$signature"

$tokenBody = @{
    client_id             = $AppID
    scope                 = "https://graph.microsoft.com/.default"
    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion      = $clientAssertion
    grant_type            = "client_credentials"
}

Try {
    $tokenResponse = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $tokenBody -ErrorAction Stop
    $headers = @{
        "Authorization" = "Bearer $($tokenResponse.access_token)"
        "Content-Type"  = "application/json"
    }
    Write-Host "Authenticated to Microsoft Graph"
    Write-Host ""
}
Catch {
    Write-Host "Authentication failed: $_"
    Stop-Transcript
    Exit 1
}

# ======================== PROCESS EACH DEVICE ==================

$BuildLogs     = @()
$totalDeleted  = 0
$totalFailed   = 0
$totalNotFound = 0

foreach ($DeviceId in $DeviceIds) {

    Write-Host "###################################################"
    Write-Host "  Processing Device ID: $DeviceId"
    Write-Host "###################################################"
    Write-Host ""

    $intuneDevice   = $null
    $entraDevice    = $null
    $deviceName     = "Unknown"
    $intuneNotFound = $false
    $entraNotFound  = $false
    $intuneDeleted  = 0
    $entraDeleted   = 0
    $intuneFailed   = 0
    $entraFailed    = 0
    $intuneSkipped  = 0
    $entraSkipped   = 0

    # Resolve Intune Object ID from Device ID (azureADDeviceId)
    If ($RemoveFrom -in @("IntuneOnly", "Both")) {
        Write-Host "Searching Intune for Device ID: $DeviceId..."
        Try {
            $filter        = "azureADDeviceId eq '$DeviceId'"
            $encoded       = [System.Uri]::EscapeDataString($filter)
            $uri           = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$encoded"
            $response      = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
            $intuneResults = @($response.value)

            If ($intuneResults.Count -eq 0) {
                Write-Host "  NOT FOUND in Intune." -ForegroundColor Yellow
                $intuneNotFound = $true
            } Else {
                $intuneDevice = $intuneResults[0]
                $deviceName   = $intuneDevice.deviceName
                Write-Host "  Found: $($intuneDevice.deviceName) (Object ID: $($intuneDevice.id))" -ForegroundColor Green
            }
        }
        Catch {
            Write-Host "  Error querying Intune: $_" -ForegroundColor Yellow
            $intuneNotFound = $true
        }
    }

    # Resolve Entra Object ID from Device ID (deviceId)
    If ($RemoveFrom -in @("EntraOnly", "Both")) {
        Write-Host "Searching Entra for Device ID: $DeviceId..."
        Try {
            $filter       = "deviceId eq '$DeviceId'"
            $encoded      = [System.Uri]::EscapeDataString($filter)
            $uri          = "https://graph.microsoft.com/v1.0/devices?`$filter=$encoded&`$select=id,displayName,deviceId,operatingSystem,operatingSystemVersion,trustType,isManaged,isCompliant,accountEnabled,approximateLastSignInDateTime,registrationDateTime"
            $response     = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
            $entraResults = @($response.value)

            If ($entraResults.Count -eq 0) {
                Write-Host "  NOT FOUND in Entra." -ForegroundColor Yellow
                $entraNotFound = $true
            } Else {
                $entraDevice = $entraResults[0]
                If ($deviceName -eq "Unknown") { $deviceName = $entraDevice.displayName }
                Write-Host "  Found: $($entraDevice.displayName) (Object ID: $($entraDevice.id))" -ForegroundColor Green
                If ($entraResults.Count -gt 1) {
                    Write-Host "  WARNING: $($entraResults.Count) Entra records found for this Device ID. Using first one." -ForegroundColor Yellow
                    For ($i = 1; $i -lt $entraResults.Count; $i++) {
                        Write-Host "    [$($i+1)] $($entraResults[$i].displayName) | Trust: $($entraResults[$i].trustType) | Object ID: $($entraResults[$i].id)"
                    }
                }
            }
        }
        Catch {
            Write-Host "  Error querying Entra: $_" -ForegroundColor Yellow
            $entraNotFound = $true
        }
    }

    $allNotFound = $false
    If ($RemoveFrom -eq "Both"       -and $intuneNotFound -and $entraNotFound) { $allNotFound = $true }
    If ($RemoveFrom -eq "IntuneOnly" -and $intuneNotFound)                     { $allNotFound = $true }
    If ($RemoveFrom -eq "EntraOnly"  -and $entraNotFound)                      { $allNotFound = $true }

    If ($allNotFound) {
        Write-Host "  Device not found with Device ID: $DeviceId" -ForegroundColor Yellow
        $totalNotFound++
    }

    If (-not $allNotFound) {

        # ---- DISPLAY DETAILS ----
        Write-Host ""
        Write-Host "============================================"
        Write-Host "  DEVICE DETAILS"
        Write-Host "============================================"

        If ($intuneDevice) {
            Write-Host "  --- Intune Record ---"
            Write-Host "  Device Name:     $($intuneDevice.deviceName)"
            Write-Host "  User:            $($intuneDevice.userDisplayName) ($($intuneDevice.userPrincipalName))"
            Write-Host "  OS:              $($intuneDevice.operatingSystem) $($intuneDevice.osVersion)"
            Write-Host "  Model:           $($intuneDevice.manufacturer) $($intuneDevice.model)"
            Write-Host "  Serial:          $($intuneDevice.serialNumber)"
            Write-Host "  Compliance:      $($intuneDevice.complianceState)"
            Write-Host "  Enrolled:        $($intuneDevice.enrolledDateTime)"
            Write-Host "  Last Sync:       $($intuneDevice.lastSyncDateTime)"
            Write-Host "  Management:      $($intuneDevice.managementAgent)"
            Write-Host "  Object ID:       $($intuneDevice.id)"
            Write-Host ""
        }

        If ($entraDevice) {
            Write-Host "  --- Entra Record ---"
            Write-Host "  Device Name:     $($entraDevice.displayName)"
            Write-Host "  Trust Type:      $($entraDevice.trustType)"
            Write-Host "  Managed:         $($entraDevice.isManaged)"
            Write-Host "  Compliant:       $($entraDevice.isCompliant)"
            Write-Host "  Enabled:         $($entraDevice.accountEnabled)"
            Write-Host "  OS:              $($entraDevice.operatingSystem) $($entraDevice.operatingSystemVersion)"
            Write-Host "  Last Sign-In:    $($entraDevice.approximateLastSignInDateTime)"
            Write-Host "  Registered:      $($entraDevice.registrationDateTime)"
            Write-Host "  Object ID:       $($entraDevice.id)"
            Write-Host ""
        }

        Write-Host "============================================"
        Write-Host ""

        # ---- DELETE ----
        If ($RemoveFrom -in @("IntuneOnly", "Both")) {
            Write-Host "============================================"
            Write-Host "  DELETING FROM INTUNE"
            Write-Host "============================================"
            If ($intuneNotFound) {
                Write-Host "  Intune record not found - skipping. (Not an error)" -ForegroundColor Yellow
                $intuneSkipped = 1
            } Else {
                Write-Host "  Deleting '$($intuneDevice.deviceName)' (ID: $($intuneDevice.id))... " -NoNewline
                Try {
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($intuneDevice.id)" -Headers $headers -Method Delete -ErrorAction Stop
                    Write-Host "SUCCESS"
                    $intuneDeleted = 1
                    $totalDeleted++
                }
                Catch {
                    Write-Host "FAILED: $_"
                    $intuneFailed = 1
                    $totalFailed++
                }
            }
            Write-Host ""
        }

        If ($RemoveFrom -in @("EntraOnly", "Both")) {
            Write-Host "============================================"
            Write-Host "  DELETING FROM ENTRA"
            Write-Host "============================================"
            If ($entraNotFound) {
                Write-Host "  Entra record not found - skipping. (Not an error)" -ForegroundColor Yellow
                $entraSkipped = 1
            } Else {
                Write-Host "  Deleting '$($entraDevice.displayName)' (ID: $($entraDevice.id))... " -NoNewline
                Try {
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices/$($entraDevice.id)" -Headers $headers -Method Delete -ErrorAction Stop
                    Write-Host "SUCCESS"
                    $entraDeleted = 1
                    $totalDeleted++
                }
                Catch {
                    Write-Host "FAILED: $_"
                    $entraFailed = 1
                    $totalFailed++
                }
            }
            Write-Host ""
        }

        # ---- PER-DEVICE RESULT ----
        Write-Host "============================================"
        Write-Host "  RESULT — $deviceName"
        Write-Host "============================================"
        If ($RemoveFrom -in @("IntuneOnly", "Both")) {
            If ($intuneSkipped) { Write-Host "  Intune:   SKIPPED (not found)" }
            Else                { Write-Host "  Intune:   $(If ($intuneDeleted) { 'DELETED' } Else { 'FAILED' })" }
        }
        If ($RemoveFrom -in @("EntraOnly", "Both")) {
            If ($entraSkipped) { Write-Host "  Entra:    SKIPPED (not found)" }
            Else               { Write-Host "  Entra:    $(If ($entraDeleted) { 'DELETED' } Else { 'FAILED' })" }
        }
        Write-Host "============================================"
        Write-Host ""

    } # End If -not $allNotFound

    # ---- BUILD LOG ENTRY ----
    $BuildLogs += [pscustomobject]@{
        Date           = $Date
        Submitter      = $($env:BUILD_USER)
        Ticket         = $($env:TicketNumber)
        RemoveFrom     = $RemoveFrom
        DeviceId       = $DeviceId
        DeviceName     = $deviceName
        IntuneObjectId = If ($intuneDevice) { $intuneDevice.id } Else { "N/A" }
        EntraObjectId  = If ($entraDevice)  { $entraDevice.id  } Else { "N/A" }
        IntuneDeleted  = If ($RemoveFrom -notin @("IntuneOnly", "Both")) { "N/A" } ElseIf ($allNotFound -or $intuneNotFound) { "Not Found" } ElseIf ($intuneSkipped) { "Skipped" } ElseIf ($intuneDeleted) { "Deleted" } ElseIf ($intuneFailed) { "Failed" } Else { "N/A" }
        EntraDeleted   = If ($RemoveFrom -notin @("EntraOnly", "Both")) { "N/A" } ElseIf ($allNotFound -or $entraNotFound) { "Not Found" } ElseIf ($entraSkipped) { "Skipped" } ElseIf ($entraDeleted) { "Deleted" } ElseIf ($entraFailed) { "Failed" } Else { "N/A" }
        User           = If ($intuneDevice) { "$($intuneDevice.userDisplayName) ($($intuneDevice.userPrincipalName))" } Else { "N/A" }
        OS             = If ($intuneDevice) { "$($intuneDevice.operatingSystem) $($intuneDevice.osVersion)" } ElseIf ($entraDevice) { "$($entraDevice.operatingSystem) $($entraDevice.operatingSystemVersion)" } Else { "N/A" }
        Serial         = If ($intuneDevice) { $intuneDevice.serialNumber } Else { "N/A" }
        Model          = If ($intuneDevice) { "$($intuneDevice.manufacturer) $($intuneDevice.model)" } Else { "N/A" }
    }

} # End foreach DeviceId

# ======================== FINAL SUMMARY ========================

Write-Host "###################################################"
Write-Host "  FINAL SUMMARY — $($DeviceIds.Count) Device(s) Processed"
Write-Host "###################################################"
Write-Host "  Submitted:   $($DeviceIds.Count)"
Write-Host "  Deleted:     $totalDeleted"
Write-Host "  Not Found:   $totalNotFound"
Write-Host "  Failed:      $totalFailed"
Write-Host "###################################################"
Write-Host ""

# ======================== LOG & NOTIFY =========================

$From       = 'jenkins@example.com'
$To         = 'ops-team@example.com'
$SmtpServer = 'smtp.example.com'

$removeLabel = Switch ($RemoveFrom) {
    "IntuneOnly" { "Intune" }
    "EntraOnly"  { "Entra" }
    "Both"       { "Intune & Entra" }
}

If ($totalFailed -gt 0) {
    $EmailSubject = "Jenkins - Device Removal FAILURES ($totalFailed failed) - $($env:TicketNumber)"
} ElseIf ($totalNotFound -gt 0 -and $totalDeleted -eq 0) {
    $EmailSubject = "Jenkins - Device Not Found ($removeLabel) - $($env:TicketNumber)"
} Else {
    $EmailSubject = "Jenkins - $totalDeleted Device(s) Removed from $removeLabel - $($env:TicketNumber)"
}

$purdyHeader = @"
<style>
TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;}
TH {text-align: center;border-width: 1px; padding: 5px; border-style: solid; border-color: black;}
TD {text-align: center;border-width: 1px; padding: 5px; border-style: solid; border-color: black; white-space: pre;}
</style>
"@

$htmlReport = $BuildLogs | ConvertTo-Html -Head $purdyHeader -As Table
$EmailBody  = "Jenkins removed $totalDeleted of $($DeviceIds.Count) device(s) from $removeLabel`:<br><br>$htmlReport"

Try {
    Send-MailMessage -From $From -To $To -Subject $EmailSubject -Body $EmailBody -BodyAsHtml -SmtpServer $SmtpServer
    Write-Host "Email notification sent."
}
Catch {
    Write-Host "Failed to send email: $_"
}

$BuildLogs | Export-CSV D:\JenkinsLogs\Remove-DeviceByDeviceId-log.csv -Append -NoTypeInformation

Stop-Transcript

If ($totalFailed -gt 0 -or ($totalNotFound -gt 0 -and $totalDeleted -eq 0)) {
    Exit 1
}
