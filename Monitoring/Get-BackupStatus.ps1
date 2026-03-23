<#
.SYNOPSIS
    Aggregates backup status from Veeam and Azure Backup.

.DESCRIPTION
    Checks Veeam backup job results via PowerShell module and Azure Backup
    vault status via Graph/Azure REST API. Generates a consolidated status
    report with pass/fail/warning indicators.

.PARAMETER VeeamServers
    Array of Veeam server hostnames to check.

.PARAMETER AzureVaultName
    Name of the Azure Recovery Services vault.

.EXAMPLE
    .\Get-BackupStatus.ps1 -VeeamServers @("veeam01","veeam02") -AzureVaultName "prod-vault"
#>

param(
    [string[]]$VeeamServers = @("localhost"),
    [string]$AzureVaultName,
    [string]$OutputPath = "$PSScriptRoot\..\Reports"
)

$report = @()

# --- Veeam Backup Jobs ---
Write-Host "Checking Veeam backup jobs..." -ForegroundColor Cyan

foreach ($server in $VeeamServers) {
    Write-Host "  Server: $server" -ForegroundColor Gray

    try {
        # Requires VeeamPSSnapin or Veeam.Backup.PowerShell module
        $session = if ($server -eq "localhost") { $null } else {
            New-PSSession -ComputerName $server -ErrorAction Stop
        }

        $scriptBlock = {
            try {
                Add-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue
                Import-Module Veeam.Backup.PowerShell -ErrorAction SilentlyContinue

                $jobs = Get-VBRJob -ErrorAction Stop
                foreach ($job in $jobs) {
                    $lastSession = $job.FindLastSession()
                    [PSCustomObject]@{
                        JobName    = $job.Name
                        Type       = $job.JobType
                        Status     = if ($lastSession) { $lastSession.Result.ToString() } else { "NoHistory" }
                        LastRun    = if ($lastSession) { $lastSession.EndTime } else { "Never" }
                        NextRun    = $job.GetScheduleOptions().NextRun
                        IsEnabled  = $job.IsScheduleEnabled
                    }
                }
            }
            catch {
                [PSCustomObject]@{
                    JobName = "ERROR"; Type = "N/A"; Status = $_.Exception.Message
                    LastRun = "N/A"; NextRun = "N/A"; IsEnabled = $false
                }
            }
        }

        $jobs = if ($session) {
            Invoke-Command -Session $session -ScriptBlock $scriptBlock
        }
        else {
            & $scriptBlock
        }

        foreach ($job in $jobs) {
            $statusLevel = switch ($job.Status) {
                "Success" { "PASS" }
                "Warning" { "WARN" }
                default   { "FAIL" }
            }

            $report += [PSCustomObject]@{
                Source     = "Veeam ($server)"
                JobName    = $job.JobName
                Type       = $job.Type
                Status     = $statusLevel
                Detail     = $job.Status
                LastRun    = $job.LastRun
                NextRun    = $job.NextRun
                Enabled    = $job.IsEnabled
            }
        }

        if ($session) { Remove-PSSession $session }
    }
    catch {
        Write-Host "  Failed to connect to $server`: $($_.Exception.Message)" -ForegroundColor Red
        $report += [PSCustomObject]@{
            Source = "Veeam ($server)"; JobName = "CONNECTION ERROR"
            Type = "N/A"; Status = "FAIL"; Detail = $_.Exception.Message
            LastRun = "N/A"; NextRun = "N/A"; Enabled = $false
        }
    }
}

# --- Azure Backup (if vault specified) ---
if ($AzureVaultName) {
    Write-Host "Checking Azure Backup vault: $AzureVaultName..." -ForegroundColor Cyan

    try {
        $headers = & "$PSScriptRoot\..\Graph-API\Get-MsToken.ps1" -Service Azure

        # List backup items
        $subscriptionId = "YOUR_SUBSCRIPTION_ID"
        $resourceGroup = "YOUR_RESOURCE_GROUP"
        $vaultUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.RecoveryServices/vaults/$AzureVaultName/backupJobs?api-version=2023-01-01&`$filter=startTime ge '$((Get-Date).AddDays(-1).ToString("yyyy-MM-ddTHH:mm:ssZ"))'"

        $azJobs = Invoke-RestMethod -Uri $vaultUri -Headers $headers -Method GET

        foreach ($job in $azJobs.value) {
            $props = $job.properties
            $statusLevel = switch ($props.status) {
                "Completed"  { "PASS" }
                "InProgress" { "WARN" }
                default      { "FAIL" }
            }

            $report += [PSCustomObject]@{
                Source   = "Azure Backup"
                JobName  = $props.entityFriendlyName
                Type     = $props.backupManagementType
                Status   = $statusLevel
                Detail   = $props.status
                LastRun  = $props.startTime
                NextRun  = "Scheduled"
                Enabled  = $true
            }
        }
    }
    catch {
        Write-Host "  Azure Backup check failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Summary ---
$passed = ($report | Where-Object { $_.Status -eq "PASS" }).Count
$warned = ($report | Where-Object { $_.Status -eq "WARN" }).Count
$failed = ($report | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host "`nBackup Status Summary:" -ForegroundColor Yellow
Write-Host "  Passed: $passed | Warnings: $warned | Failed: $failed | Total: $($report.Count)"

if ($failed -gt 0) {
    Write-Host "  CRITICAL: $failed backup job(s) failed!" -ForegroundColor Red
}

# --- Export ---
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutputPath "BackupStatus_$timestamp.xlsx"

$report | Export-Excel -Path $outFile `
    -WorksheetName "Backup Status" `
    -AutoSize -FreezeTopRow -AutoFilter -BoldTopRow `
    -ConditionalText $(
        New-ConditionalText -Text "FAIL" -BackgroundColor "#FFCCCC" -ConditionalTextColor "#CC0000"
        New-ConditionalText -Text "WARN" -BackgroundColor "#FFFFCC" -ConditionalTextColor "#CC6600"
        New-ConditionalText -Text "PASS" -BackgroundColor "#CCFFCC" -ConditionalTextColor "#006600"
    )

Write-Host "Report exported: $outFile" -ForegroundColor Green
