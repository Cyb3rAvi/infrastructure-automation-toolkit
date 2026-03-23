# Infrastructure Automation Scripts

A collection of PowerShell scripts for managing enterprise IT infrastructure. Built for real-world environments using Microsoft Graph API, Intune, Entra ID, Exchange Online, Okta, Freshservice, and Jenkins.

## Structure

```
infra-automation-scripts/
├── Graph-API/            → Microsoft Graph authentication with token caching
├── Intune/               → Device reporting, BitLocker compliance, readiness assessment, kiosk config, stale cleanup
├── Entra-ID/             → Stale device detection, hybrid AD device inventory
├── Exchange/             → Mailbox reporting, calendar permissions, distribution list management
├── Okta/                 → User access reporting with API pagination
├── Freshservice/         → Ticket details retrieval, note posting
├── Business-Central/     → User permission audit with elevated access flagging
├── Monitoring/           → Service health checks, Veeam/Azure backup status
├── Browser-Policy/       → HKLM-based browser homepage enforcement (Intune remediation)
└── Jenkins/              → Certificate-based automated device lifecycle cleanup
```

## Scripts

| Folder | Script | Description |
|--------|--------|-------------|
| Graph-API | `Get-MsToken.ps1` | Token auth with caching for Graph, Exchange, SharePoint, Azure |
| Intune | `Get-DeviceReport.ps1` | Device info, encryption status, recovery keys |
| Intune | `Get-BitLockerReport.ps1` | Phased BitLocker compliance reporting |
| Intune | `Get-DeviceReadiness.ps1` | SecureBoot, VT-x, UEFI, disk assessment |
| Intune | `Deploy-KioskConfig.ps1` | iOS kiosk mode with web content filtering |
| Intune | `Remove-StaleDevices.ps1` | Stale device cleanup from Entra/Intune |
| Entra-ID | `Get-StaleDevices.ps1` | Entra vs Intune cross-reference, orphan detection |
| Entra-ID | `Get-DeviceInventory.ps1` | Full hybrid AD device inventory |
| Exchange | `Get-MailboxReport.ps1` | Mailbox size, permissions, delegates |
| Exchange | `Update-CalendarPermissions.ps1` | Calendar delegation management |
| Exchange | `Update-DistributionList.ps1` | Bulk DL membership management |
| Okta | `Get-OktaAccessReport.ps1` | User/app/role report with pagination |
| Freshservice | `Get-TicketDetails.ps1` | Ticket info and conversation history |
| Freshservice | `Add-TicketNote.ps1` | Post private/public notes via API |
| Business-Central | `Build-BCAccessReport.ps1` | User permission audit with elevated access flagging |
| Monitoring | `Test-ServiceHealth.ps1` | Web, TCP, and Windows service health checks |
| Monitoring | `Get-BackupStatus.ps1` | Veeam and Azure Backup status aggregator |
| Browser-Policy | `Set-BrowserHomepage.ps1` | HKLM registry-based Edge/Chrome homepage enforcement |
| Jenkins | `Remove-IntuneDevice.ps1` | Automated device removal with cert-based JWT auth |

## Requirements

- PowerShell 7+ (`pwsh`)
- [ImportExcel](https://github.com/dfinke/ImportExcel) module for Excel exports
- [ExchangeOnlineManagement](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) for Exchange scripts
- Appropriate API permissions for each service

## Usage

Each folder contains standalone scripts with inline documentation. Update the configuration variables at the top of each script (tenant ID, API keys, etc.) before running.

```powershell
# Generate an Intune device report
.\Intune\Get-DeviceReport.ps1

# Check BitLocker compliance for a phase
.\Intune\Get-BitLockerReport.ps1 -InputFile "phase1.txt" -Phase "Phase1"

# Get Okta access review report
.\Okta\Get-OktaAccessReport.ps1

# Check infrastructure health
.\Monitoring\Test-ServiceHealth.ps1
```

## Authentication

Most scripts use token-based authentication:
- **Graph API**: Client credentials with token caching (`Graph-API/Get-MsToken.ps1`)
- **Okta**: SSWS API token
- **Freshservice**: Basic auth with API key
- **Jenkins**: Certificate-based JWT
- **Exchange Online**: ExchangeOnlineManagement module (interactive or app-based)

## Notes

- All scripts are **read-only** unless explicitly noted — no changes to production systems
- Credentials and tenant-specific values are placeholders — update before use
- Designed for enterprise environments managing 400+ endpoints
- Large data imports (500K+ rows) should use CSV format for performance

## License

MIT
