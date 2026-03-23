<#
.SYNOPSIS
    Automated device removal from Intune and Entra ID via Jenkins pipeline.

.DESCRIPTION
    Designed to run as a Jenkins job for automated device lifecycle cleanup.
    Authenticates using certificate-based JWT (no interactive login).
    Removes a device from both Intune and Entra ID by hostname.

.PARAMETER DeviceName
    The hostname of the device to remove.

.PARAMETER EntraOnly
    If specified, only removes from Entra ID (skips Intune).

.NOTES
    - Runs under SYSTEM account on Jenkins server
    - Uses certificate thumbprint for authentication (no client secret)
    - Designed for PowerShell 5.1 compatibility (Jenkins default)
#>

param(
    [Parameter(Mandatory)]
    [string]$DeviceName,

    [switch]$EntraOnly
)

# --- Configuration (update these) ---
$tenantId   = "YOUR_TENANT_ID"
$clientId   = "YOUR_CLIENT_ID"
$thumbprint = "YOUR_CERT_THUMBPRINT"

# --- Certificate-Based JWT Auth ---
function Get-JwtToken {
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $thumbprint }
    if (-not $cert) {
        throw "Certificate with thumbprint $thumbprint not found in LocalMachine\My"
    }

    # JWT Header
    $header = @{ alg = "RS256"; typ = "JWT"; x5t = [Convert]::ToBase64String($cert.GetCertHash()) } |
        ConvertTo-Json -Compress
    $headerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($header)).TrimEnd('=').Replace('+','-').Replace('/','_')

    # JWT Payload
    $now = [int](Get-Date (Get-Date).ToUniversalTime() -UFormat %s)
    $payload = @{
        aud = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        iss = $clientId
        sub = $clientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now
        exp = $now + 600
    } | ConvertTo-Json -Compress
    $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')

    # Sign
    $dataToSign = [Text.Encoding]::UTF8.GetBytes("$headerB64.$payloadB64")
    $rsa = $cert.PrivateKey
    $signature = $rsa.SignData($dataToSign, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $signatureB64 = [Convert]::ToBase64String($signature).TrimEnd('=').Replace('+','-').Replace('/','_')

    $jwt = "$headerB64.$payloadB64.$signatureB64"

    # Exchange JWT for access token
    $body = @{
        grant_type            = "client_credentials"
        client_id             = $clientId
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion      = $jwt
        scope                 = "https://graph.microsoft.com/.default"
    }

    $token = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded"

    return $token.access_token
}

# --- Auth ---
Write-Host "Authenticating with certificate..." -ForegroundColor Cyan
$accessToken = Get-JwtToken
$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# --- Find Device in Intune ---
if (-not $EntraOnly) {
    Write-Host "Searching Intune for '$DeviceName'..." -ForegroundColor Cyan
    $encoded = [System.Uri]::EscapeDataString($DeviceName)
    $intuneResult = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$encoded'" -Headers $headers

    if ($intuneResult.value.Count -gt 0) {
        foreach ($device in $intuneResult.value) {
            Write-Host "Removing from Intune: $($device.deviceName) (ID: $($device.id))" -ForegroundColor Yellow
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)" -Headers $headers -Method DELETE
            Write-Host "Removed from Intune." -ForegroundColor Green
        }
    }
    else {
        Write-Host "Not found in Intune." -ForegroundColor Gray
    }
}

# --- Find Device in Entra ID ---
Write-Host "Searching Entra ID for '$DeviceName'..." -ForegroundColor Cyan
$entraResult = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$encoded'" -Headers $headers

if ($entraResult.value.Count -gt 0) {
    foreach ($device in $entraResult.value) {
        Write-Host "Removing from Entra ID: $($device.displayName) (ID: $($device.id))" -ForegroundColor Yellow
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" -Headers $headers -Method DELETE
        Write-Host "Removed from Entra ID." -ForegroundColor Green
    }
}
else {
    Write-Host "Not found in Entra ID." -ForegroundColor Gray
}

Write-Host "`nDevice cleanup complete for '$DeviceName'." -ForegroundColor Cyan
