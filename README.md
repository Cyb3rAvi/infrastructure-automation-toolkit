# Infrastructure Automation Scripts

PowerShell scripts for day-to-day Microsoft 365 and infrastructure administration: devices and compliance (Intune, Entra ID), mail (Exchange Online), identity reviews (Okta, Business Central), service desk (Freshservice), monitoring and backup status. They come from real enterprise work (400+ endpoints) and have been cleaned of company-specific values.

**Before you run anything:** these are examples to read, adapt and test, not tools to point at production. Some scripts were drafted with an AI coding assistant; I reviewed and edited them, but treat every script as an example and test it before use. Fill in the placeholders, try them on a test tenant or a small group first, and read the "What it changes" column below.

## What it changes

Every script is listed with what it can do to your environment, so you know which ones are safe to run for a look-around and which need care.

### Read-only (reports and checks)

| Folder | Script | What it does |
|--------|--------|--------------|
| Graph-API | `Get-MsToken.ps1` | Gets and caches an access token for Graph, Exchange, SharePoint or Azure. Changes nothing in the tenant; writes a local token cache file in your user profile. |
| Intune | `Get-DeviceReport.ps1` | Device details, encryption status and recovery keys. |
| Intune | `Get-BitLockerReport.ps1` | BitLocker compliance by rollout phase, from a list of devices. |
| Intune | `Get-DeviceReadiness.ps1` | Checks Secure Boot, virtualization, UEFI and disk, to see which devices are ready for a change. |
| Entra-ID | `Get-StaleDevices.ps1` | Compares Entra and Intune to find stale and orphaned devices. |
| Entra-ID | `Get-DeviceInventory.ps1` | Full inventory of hybrid-joined devices. |
| Exchange | `Get-MailboxReport.ps1` | Mailbox size, permissions and delegates. |
| Okta | `Get-OktaAccessReport.ps1` | Users, apps and roles for an access review (handles API paging). |
| Freshservice | `Get-TicketDetails.ps1` | Ticket details and conversation history. |
| Business-Central | `Build-BCAccessReport.ps1` | User permission audit that flags elevated access. |
| Monitoring | `Test-ServiceHealth.ps1` | Web, TCP and Windows service health checks. |
| Monitoring | `Get-BackupStatus.ps1` | Veeam and Azure Backup status in one view. |

### Changes something (read the notes first)

| Folder | Script | What it changes | Safety built in |
|--------|--------|-----------------|-----------------|
| Intune | `Remove-StaleDevices.ps1` | **Deletes** stale devices from Entra and Intune | `-DryRun` and a yes/no confirmation |
| Jenkins | `Remove-IntuneDevice.ps1` | **Deletes** every device matching a hostname from Intune and Entra | `-DryRun` (no confirmation: it is built to run unattended) |
| Exchange | `Update-DistributionList.ps1` | Adds or removes distribution list members from a CSV | `-DryRun` (no confirmation prompt) |
| Exchange | `Update-CalendarPermissions.ps1` | Adds, changes or removes calendar delegates (`List` is read-only) | `-DryRun` for Add and Remove (no confirmation prompt) |
| Intune | `Deploy-KioskConfig.ps1` | **Creates** an iOS web-filter profile and assigns it to a group (a new profile every run) | `-DryRun` |
| Freshservice | `Add-TicketNote.ps1` | Posts a note on a ticket: private by default, visible to the requester only with `-Public` | none: you cannot undo a posted note |
| Browser-Policy | `Set-BrowserHomepage.ps1` | Writes Edge and Chrome homepage policy to HKLM (an Intune remediation script) | none: it is meant to run as SYSTEM through Intune |

## Folders

```
Graph-API/        Microsoft Graph authentication with token caching
Intune/           Device reporting, BitLocker compliance, readiness, kiosk config, stale cleanup
Entra-ID/         Stale device detection, hybrid device inventory
Exchange/         Mailbox reporting, calendar permissions, distribution lists
Okta/             User access reporting
Freshservice/     Ticket details and notes
Business-Central/ Permission audit with elevated-access flagging
Monitoring/       Service health, backup status
Browser-Policy/   Browser homepage enforcement (Intune remediation)
Jenkins/          Unattended, certificate-based device cleanup
```

## Requirements

- PowerShell 7+ (`pwsh`). `Remove-IntuneDevice.ps1` is written to run on Windows PowerShell 5.1 as well, because that is the Jenkins default.
- [ImportExcel](https://github.com/dfinke/ImportExcel) for the Excel exports.
- [ExchangeOnlineManagement](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) for the Exchange scripts.
- The API permissions each service needs. Grant the least that covers the script (the read-only ones need read permissions only).

## Setup and usage

1. Set your values. The Graph scripts read `GRAPH_TENANT_ID`, `GRAPH_CLIENT_ID` and `GRAPH_CLIENT_SECRET` from environment variables first; the placeholders in the file apply only if those are not set. Other scripts have their settings at the top.
2. Run a read-only script first to check the connection.
3. For anything that changes things, run it with `-DryRun` and read the output before running it for real.

```powershell
# A read-only report
.\Intune\Get-DeviceReport.ps1

# Preview a cleanup, then run it
.\Intune\Remove-StaleDevices.ps1 -StaleDays 90 -DryRun
.\Jenkins\Remove-IntuneDevice.ps1 -DeviceName "PC-0001" -DryRun
```

## Authentication

- **Microsoft Graph:** client credentials with token caching (`Graph-API/Get-MsToken.ps1`). The cache holds live tokens in plain text in your user profile, so keep it out of any repo (the `.gitignore` already excludes it).
- **Jenkins script:** certificate-based JWT, no client secret.
- **Exchange Online:** the ExchangeOnlineManagement module (interactive or app-based).
- **Okta:** SSWS API token. **Freshservice:** API key.
- Never paste secrets into a script you will commit. Use environment variables or a secret store.

## Notes

- Values like tenant ID, client ID, group IDs and URLs are placeholders.
- Large data imports (500K+ rows) work better as CSV than Excel.
- Scripts are provided as-is. Test before relying on them.

## License

MIT, see [LICENSE](LICENSE).
