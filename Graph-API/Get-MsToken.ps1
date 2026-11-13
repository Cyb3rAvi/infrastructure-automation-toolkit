<#
.SYNOPSIS
    Authenticates to Microsoft Graph API using client credentials and caches the token locally.

.DESCRIPTION
    Supports multiple services: Graph, Exchange, SharePoint, Azure.
    Tokens are cached to a local JSON file and reused until expiry.
    Reduces repeated authentication calls in automated workflows.

.PARAMETER Service
    The Microsoft service to authenticate against.
    Valid values: Graph, Exchange, SharePoint, Azure

.EXAMPLE
    $headers = .\Get-MsToken.ps1 -Service Graph
    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me" -Headers $headers
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Graph", "Exchange", "SharePoint", "Azure")]
    [string]$Service
)

# --- Configuration ---
# Prefer environment variables (or a secret store) over editing secrets into this file.
# The placeholders below only apply when the variable is not set.
$tenantId     = if ($env:GRAPH_TENANT_ID)     { $env:GRAPH_TENANT_ID }     else { "YOUR_TENANT_ID" }
$clientId     = if ($env:GRAPH_CLIENT_ID)     { $env:GRAPH_CLIENT_ID }     else { "YOUR_CLIENT_ID" }
$clientSecret = if ($env:GRAPH_CLIENT_SECRET) { $env:GRAPH_CLIENT_SECRET } else { "YOUR_CLIENT_SECRET" }
# The cache holds live access tokens in plain text: keep it in your user profile, never in a repo.
$cachePath    = "$env:USERPROFILE\.graph-token-cache.json"

# Service-specific resource URIs
$resourceMap = @{
    Graph      = "https://graph.microsoft.com/.default"
    Exchange   = "https://outlook.office365.com/.default"
    SharePoint = "https://YOUR_TENANT.sharepoint.com/.default"
    Azure      = "https://management.azure.com/.default"
}

$scope = $resourceMap[$Service]

# --- Token Cache ---
function Get-CachedToken {
    if (Test-Path $cachePath) {
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
        if ($cache.$Service) {
            $expiry = [datetime]::Parse($cache.$Service.expires_on)
            if ($expiry -gt (Get-Date).AddMinutes(5)) {
                return $cache.$Service.access_token
            }
        }
    }
    return $null
}

function Save-TokenToCache {
    param([string]$Token, [int]$ExpiresIn)

    $cache = @{}
    if (Test-Path $cachePath) {
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable
    }

    $cache[$Service] = @{
        access_token = $Token
        expires_on   = (Get-Date).AddSeconds($ExpiresIn).ToString("o")
    }

    $cache | ConvertTo-Json -Depth 5 | Set-Content $cachePath -Force
}

# --- Auth Flow ---
$cachedToken = Get-CachedToken
if ($cachedToken) {
    Write-Host "Using cached $Service token" -ForegroundColor Green
    $accessToken = $cachedToken
}
else {
    Write-Host "Requesting new $Service token..." -ForegroundColor Yellow

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = $scope
    }

    $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $response = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $body -ContentType "application/x-www-form-urlencoded"

    $accessToken = $response.access_token
    Save-TokenToCache -Token $accessToken -ExpiresIn $response.expires_in

    Write-Host "$Service token acquired and cached" -ForegroundColor Green
}

# Return headers ready for API calls
$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

return $headers
