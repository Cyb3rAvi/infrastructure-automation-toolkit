<#
.SYNOPSIS
    Configures iOS kiosk mode with web content filtering via Intune Graph API.

.DESCRIPTION
    Creates or updates an Intune device configuration profile for supervised iOS
    devices. Sets up single-app kiosk mode or web content filtering (specificWebsitesOnly)
    for controlled browsing environments.

    Requires supervised devices enrolled via Apple Business Manager (ABM/DEP).

.PARAMETER ProfileName
    Name for the configuration profile.

.PARAMETER AllowedUrls
    Array of URLs to whitelist in the web content filter.

.PARAMETER GroupId
    Entra ID group to assign the profile to.

.EXAMPLE
    .\Deploy-KioskConfig.ps1 -ProfileName "Kiosk - Sales Registration" -AllowedUrls @("https://app.example.com") -GroupId "YOUR_GROUP_ID"
#>

param(
    [Parameter(Mandatory)]
    [string]$ProfileName,

    [Parameter(Mandatory)]
    [string[]]$AllowedUrls,

    [Parameter(Mandatory)]
    [string]$GroupId
)

# --- Auth ---
$headers = & "$PSScriptRoot\..\Graph-API\Get-MsToken.ps1" -Service Graph

# --- Build Web Filter Bookmarks ---
$bookmarks = foreach ($url in $AllowedUrls) {
    $name = ([System.Uri]$url).Host -replace '^www\.', ''
    @{
        url        = $url
        bookmarkFolder = "Allowed"
        displayName = $name
    }
}

# --- Create Profile ---
Write-Host "Creating kiosk profile: $ProfileName" -ForegroundColor Cyan

$profileBody = @{
    "@odata.type"         = "#microsoft.graph.iosDeviceFeaturesConfiguration"
    displayName           = $ProfileName
    description           = "Kiosk web content filter - supervised devices only"
    contentFilterSettings = @{
        "@odata.type"          = "#microsoft.graph.iosWebContentFilterSpecificWebsitesAccess"
        specificWebsitesOnly   = $bookmarks
        websiteList            = $bookmarks
    }
} | ConvertTo-Json -Depth 10

try {
    $profile = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations" `
        -Headers $headers -Method POST -Body $profileBody -ContentType "application/json"
    Write-Host "Profile created: $($profile.id)" -ForegroundColor Green
}
catch {
    Write-Host "Failed to create profile: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Assign to Group ---
Write-Host "Assigning to group: $GroupId" -ForegroundColor Cyan

$assignBody = @{
    assignments = @(
        @{
            target = @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                groupId       = $GroupId
            }
        }
    )
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($profile.id)/assign" `
        -Headers $headers -Method POST -Body $assignBody -ContentType "application/json"
    Write-Host "Assignment complete." -ForegroundColor Green
}
catch {
    Write-Host "Failed to assign: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nKiosk profile '$ProfileName' is ready." -ForegroundColor Cyan
Write-Host "Note: Only applies to supervised devices (ABM/DEP enrolled)." -ForegroundColor Yellow
