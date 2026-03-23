<#
.SYNOPSIS
    Bulk manages distribution list membership in Exchange Online.

.DESCRIPTION
    Adds or removes members from a distribution list using a CSV input file.
    Supports dry-run mode for safe preview before making changes.

.PARAMETER DLAddress
    Email address of the distribution list.

.PARAMETER InputFile
    Path to CSV with columns: Email, Action (Add/Remove)

.PARAMETER DryRun
    Preview changes without applying them.

.EXAMPLE
    .\Update-DistributionList.ps1 -DLAddress "team@domain.com" -InputFile "members.csv"

.EXAMPLE
    .\Update-DistributionList.ps1 -DLAddress "team@domain.com" -InputFile "members.csv" -DryRun
#>

param(
    [Parameter(Mandatory)]
    [string]$DLAddress,

    [Parameter(Mandatory)]
    [string]$InputFile,

    [switch]$DryRun
)

# --- Connect ---
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    Write-Host "Install ExchangeOnlineManagement module first." -ForegroundColor Red
    exit 1
}

Connect-ExchangeOnline -ShowBanner:$false

# --- Validate DL ---
$dl = Get-DistributionGroup -Identity $DLAddress -ErrorAction SilentlyContinue
if (-not $dl) {
    Write-Host "Distribution list not found: $DLAddress" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false
    exit 1
}

Write-Host "Distribution List: $($dl.DisplayName) ($DLAddress)" -ForegroundColor Cyan

# Get current members
$currentMembers = Get-DistributionGroupMember -Identity $DLAddress -ResultSize Unlimited |
    ForEach-Object { $_.PrimarySmtpAddress.ToLower() }

Write-Host "Current members: $($currentMembers.Count)" -ForegroundColor Green

# --- Load Input ---
if (-not (Test-Path $InputFile)) {
    Write-Host "Input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

$changes = Import-Csv $InputFile
Write-Host "Changes to process: $($changes.Count)" -ForegroundColor Cyan

# --- Process ---
$added = 0; $removed = 0; $skipped = 0; $errors = 0

foreach ($entry in $changes) {
    $email = $entry.Email.Trim().ToLower()
    $action = $entry.Action.Trim()

    switch ($action) {
        "Add" {
            if ($email -in $currentMembers) {
                Write-Host "  SKIP (already member): $email" -ForegroundColor Gray
                $skipped++
            }
            elseif ($DryRun) {
                Write-Host "  [DRY RUN] Would add: $email" -ForegroundColor Yellow
                $added++
            }
            else {
                try {
                    Add-DistributionGroupMember -Identity $DLAddress -Member $email -ErrorAction Stop
                    Write-Host "  Added: $email" -ForegroundColor Green
                    $added++
                }
                catch {
                    Write-Host "  ERROR adding $email`: $($_.Exception.Message)" -ForegroundColor Red
                    $errors++
                }
            }
        }

        "Remove" {
            if ($email -notin $currentMembers) {
                Write-Host "  SKIP (not a member): $email" -ForegroundColor Gray
                $skipped++
            }
            elseif ($DryRun) {
                Write-Host "  [DRY RUN] Would remove: $email" -ForegroundColor Yellow
                $removed++
            }
            else {
                try {
                    Remove-DistributionGroupMember -Identity $DLAddress -Member $email -Confirm:$false -ErrorAction Stop
                    Write-Host "  Removed: $email" -ForegroundColor Green
                    $removed++
                }
                catch {
                    Write-Host "  ERROR removing $email`: $($_.Exception.Message)" -ForegroundColor Red
                    $errors++
                }
            }
        }

        default {
            Write-Host "  SKIP (invalid action '$action'): $email" -ForegroundColor Yellow
            $skipped++
        }
    }
}

# --- Summary ---
$prefix = if ($DryRun) { "[DRY RUN] " } else { "" }
Write-Host "`n${prefix}Summary:" -ForegroundColor Yellow
Write-Host "  Added: $added | Removed: $removed | Skipped: $skipped | Errors: $errors"

Disconnect-ExchangeOnline -Confirm:$false
