<#
.SYNOPSIS
    Manages calendar delegate permissions in Exchange Online.

.DESCRIPTION
    Add, remove, or list calendar folder permissions for a mailbox.
    Supports common access levels: Reviewer, Editor, Author, Owner.

.PARAMETER Mailbox
    The email address of the mailbox to manage.

.PARAMETER Delegate
    The email address of the user to grant/revoke access.

.PARAMETER Action
    Add, Remove, or List. Default: List

.PARAMETER AccessLevel
    Permission level for Add action. Default: Reviewer

.PARAMETER DryRun
    For Add and Remove: show what would change without changing it. Remove has no
    confirmation prompt, so use this first.

.EXAMPLE
    .\Update-CalendarPermissions.ps1 -Mailbox "user@domain.com" -Action List

.EXAMPLE
    .\Update-CalendarPermissions.ps1 -Mailbox "user@domain.com" -Delegate "manager@domain.com" -Action Add -AccessLevel Editor
#>

param(
    [Parameter(Mandatory)]
    [string]$Mailbox,

    [string]$Delegate,

    [ValidateSet("Add", "Remove", "List")]
    [string]$Action = "List",

    [ValidateSet("Reviewer", "Editor", "Author", "Owner", "PublishingEditor")]
    [string]$AccessLevel = "Reviewer",

    [switch]$DryRun
)

# --- Connect ---
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    Write-Host "Install ExchangeOnlineManagement module first." -ForegroundColor Red
    exit 1
}

Connect-ExchangeOnline -ShowBanner:$false

$calendarPath = "${Mailbox}:\Calendar"

switch ($Action) {
    "List" {
        Write-Host "`nCalendar permissions for $Mailbox`:" -ForegroundColor Cyan
        Get-MailboxFolderPermission -Identity $calendarPath |
            Format-Table User, AccessRights, SharingPermissionFlags -AutoSize
    }

    "Add" {
        if (-not $Delegate) {
            Write-Host "Delegate parameter required for Add action." -ForegroundColor Red
            exit 1
        }

        # Check if permission already exists
        $existing = Get-MailboxFolderPermission -Identity $calendarPath -ErrorAction SilentlyContinue |
            Where-Object { $_.User.DisplayName -eq $Delegate -or $_.User.ADRecipient.PrimarySmtpAddress -eq $Delegate }

        if ($DryRun) {
            $what = if ($existing) { "update $Delegate to $AccessLevel" } else { "add $Delegate as $AccessLevel" }
            Write-Host "[DRY RUN] Would $what on $Mailbox calendar. Nothing changed." -ForegroundColor Yellow
        }
        elseif ($existing) {
            Write-Host "Updating existing permission for $Delegate to $AccessLevel..." -ForegroundColor Yellow
            Set-MailboxFolderPermission -Identity $calendarPath -User $Delegate -AccessRights $AccessLevel
        }
        else {
            Write-Host "Adding $Delegate as $AccessLevel on $Mailbox calendar..." -ForegroundColor Yellow
            Add-MailboxFolderPermission -Identity $calendarPath -User $Delegate -AccessRights $AccessLevel
        }
        if (-not $DryRun) { Write-Host "Done." -ForegroundColor Green }
    }

    "Remove" {
        if (-not $Delegate) {
            Write-Host "Delegate parameter required for Remove action." -ForegroundColor Red
            exit 1
        }

        if ($DryRun) {
            Write-Host "[DRY RUN] Would remove $Delegate from $Mailbox calendar. Nothing changed." -ForegroundColor Yellow
            break
        }
        Write-Host "Removing $Delegate from $Mailbox calendar..." -ForegroundColor Yellow
        try {
            Remove-MailboxFolderPermission -Identity $calendarPath -User $Delegate -Confirm:$false
            Write-Host "Done." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Disconnect-ExchangeOnline -Confirm:$false
