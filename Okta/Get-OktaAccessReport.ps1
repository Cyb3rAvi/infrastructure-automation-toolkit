<#
.SYNOPSIS
    Generates a user access report from Okta with app assignments and admin roles.

.DESCRIPTION
    Pulls all users, applications, app assignments, and admin roles via Okta REST API.
    Handles pagination automatically. Exports formatted Excel report with
    conditional formatting and review columns.

.EXAMPLE
    .\Get-OktaAccessReport.ps1
    Generates full Okta access review report.
#>

param(
    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

# --- Configuration (update these) ---
$oktaDomain   = "YOUR_ORG.okta.com"
$oktaApiToken = "YOUR_OKTA_API_TOKEN"

$oktaHeaders = @{
    Authorization  = "SSWS $oktaApiToken"
    "Content-Type" = "application/json"
    Accept         = "application/json"
}

# --- Pagination Helper ---
function Get-OktaAllPages {
    param([string]$Uri)
    $all = @()
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-WebRequest -Uri $nextUri -Headers $oktaHeaders -Method GET
        $all += ($response.Content | ConvertFrom-Json)

        # Okta uses Link header for pagination
        $linkHeader = $response.Headers["Link"]
        $nextUri = $null
        if ($linkHeader) {
            $links = if ($linkHeader -is [array]) { $linkHeader } else { @($linkHeader) }
            foreach ($link in $links) {
                if ($link -match '<([^>]+)>;\s*rel="next"') {
                    $nextUri = $Matches[1]
                }
            }
        }
    }
    return $all
}

# --- Pull Data ---
Write-Host "Pulling Okta users..." -ForegroundColor Cyan
$users = Get-OktaAllPages -Uri "https://$oktaDomain/api/v1/users?limit=200"
Write-Host "Found $($users.Count) users" -ForegroundColor Green

Write-Host "Pulling applications..." -ForegroundColor Cyan
$apps = Get-OktaAllPages -Uri "https://$oktaDomain/api/v1/apps?limit=200"
Write-Host "Found $($apps.Count) apps" -ForegroundColor Green

# --- App Assignments ---
Write-Host "Pulling app assignments..." -ForegroundColor Cyan
$appAssignments = @{}
foreach ($app in $apps) {
    $appUsers = Get-OktaAllPages -Uri "https://$oktaDomain/api/v1/apps/$($app.id)/users?limit=200"
    foreach ($au in $appUsers) {
        $userId = $au.id
        if (-not $appAssignments[$userId]) { $appAssignments[$userId] = @() }
        $appAssignments[$userId] += $app.label
    }
}

# --- Admin Roles ---
Write-Host "Checking admin roles..." -ForegroundColor Cyan
$adminUsers = @{}
foreach ($user in $users) {
    try {
        $roles = Invoke-RestMethod -Uri "https://$oktaDomain/api/v1/users/$($user.id)/roles" -Headers $oktaHeaders -Method GET
        if ($roles.Count -gt 0) {
            $adminUsers[$user.id] = ($roles | ForEach-Object { $_.type }) -join ", "
        }
    }
    catch { }
}

# --- Build Report ---
Write-Host "Building report..." -ForegroundColor Cyan

$report = foreach ($user in $users) {
    $uid = $user.id
    $roles = if ($adminUsers[$uid]) { $adminUsers[$uid] } else { "None" }
    $assignedApps = if ($appAssignments[$uid]) { ($appAssignments[$uid] | Sort-Object -Unique) -join ", " } else { "None" }
    $appCount = if ($appAssignments[$uid]) { ($appAssignments[$uid] | Sort-Object -Unique).Count } else { 0 }

    # Flag elevated access
    $isAdmin = $roles -ne "None"
    $isServiceAccount = $user.profile.login -match "svc\.|service|api|bot|system"

    [PSCustomObject]@{
        FirstName         = $user.profile.firstName
        LastName          = $user.profile.lastName
        Email             = $user.profile.email
        Login             = $user.profile.login
        Status            = $user.status
        UserType          = $user.profile.userType
        Department        = $user.profile.department
        Title             = $user.profile.title
        AdminRoles        = $roles
        IsAdmin           = $isAdmin
        AppCount          = $appCount
        AssignedApps      = $assignedApps
        IsServiceAccount  = $isServiceAccount
        LastLogin         = $user.lastLogin
        Created           = $user.created
        # Review columns
        AccessAppropriate = ""
        ActionRequired    = ""
        Comments          = ""
    }
}

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "OktaAccessReport_$timestamp.xlsx"

$report | Export-Excel -Path $outFile `
    -WorksheetName "Access Review" `
    -AutoSize `
    -FreezeTopRow `
    -AutoFilter `
    -BoldTopRow `
    -ConditionalText $(
        New-ConditionalText -Text "True" -BackgroundColor "#FFCCCC" -ConditionalTextColor "#CC0000"
        New-ConditionalText -Text "SUSPENDED" -BackgroundColor "#FFFFCC" -ConditionalTextColor "#CC6600"
        New-ConditionalText -Text "DEPROVISIONED" -BackgroundColor "#FFE0CC" -ConditionalTextColor "#CC3300"
    )

Write-Host "Report exported: $outFile" -ForegroundColor Green
Write-Host "Users: $($users.Count) | Admins: $($adminUsers.Count) | Apps: $($apps.Count)" -ForegroundColor Cyan
