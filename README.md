# Infrastructure Automation Scripts

A collection of PowerShell scripts for managing enterprise IT infrastructure. Built for real-world environments using Microsoft Graph API, Intune, Entra ID, Exchange Online, Okta, Freshservice, and Jenkins.

## Structure

```
infra-automation-scripts/
├── Graph-API/          → Microsoft Graph authentication with token caching
├── Intune/             → Device reporting, readiness assessment, stale device cleanup
├── Exchange/           → Mailbox reporting, calendar permission management
├── Okta/               → User access reporting with API pagination
├── Freshservice/       → Ticket details and conversation retrieval
└── Jenkins/            → Automated device lifecycle cleanup
```

## Requirements

- PowerShell 7+ (`pwsh`)
- [ImportExcel](https://github.com/dfinke/ImportExcel) module for Excel exports
- Appropriate API permissions for each service

## Usage

Each folder contains standalone scripts with inline documentation. Update the configuration variables at the top of each script (tenant ID, API keys, etc.) before running.

```powershell
# Example: Generate an Intune device report
.\Intune\Get-DeviceReport.ps1

# Example: Get Okta access review report
.\Okta\Get-OktaAccessReport.ps1
```

## Authentication

Most scripts use token-based authentication:
- **Graph API**: Client credentials with token caching (`Graph-API/Get-MsToken.ps1`)
- **Okta**: SSWS API token
- **Freshservice**: Basic auth with API key
- **Jenkins**: Certificate-based JWT

## Notes

- All scripts are **read-only** unless explicitly noted — no changes to production systems
- Credentials and tenant-specific values are placeholders — update before use
- Designed for enterprise environments managing 400+ endpoints

## License

MIT
