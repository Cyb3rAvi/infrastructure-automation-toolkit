<#
.SYNOPSIS
    Checks health status of critical infrastructure services.

.DESCRIPTION
    Tests connectivity and availability of key services: web endpoints,
    Windows services, TCP ports, and SQL databases. Outputs a summary
    with pass/fail status for each check.

.PARAMETER ConfigFile
    Path to JSON config file defining services to check. If not provided,
    uses a default set of checks.

.EXAMPLE
    .\Test-ServiceHealth.ps1
    Runs default health checks.

.EXAMPLE
    .\Test-ServiceHealth.ps1 -ConfigFile "services.json"
    Runs checks defined in the config file.
#>

param(
    [string]$ConfigFile
)

# --- Default Checks (override with ConfigFile) ---
$defaultChecks = @{
    WebEndpoints = @(
        @{ Name = "Lansweeper"; Url = "https://YOUR_LANSWEEPER_URL"; ExpectedStatus = 200 }
        @{ Name = "Freshservice"; Url = "https://YOUR_DOMAIN.freshservice.com"; ExpectedStatus = 200 }
    )
    TcpPorts = @(
        @{ Name = "PRTG Server"; Host = "YOUR_PRTG_HOST"; Port = 443 }
        @{ Name = "SQL Server"; Host = "YOUR_SQL_HOST"; Port = 1433 }
    )
    WindowsServices = @(
        @{ Name = "Veeam Backup"; ServiceName = "VeeamBackupSvc"; ComputerName = "localhost" }
    )
}

if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $checks = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
}
else {
    $checks = $defaultChecks
}

$results = @()

# --- Web Endpoint Checks ---
if ($checks.WebEndpoints) {
    Write-Host "`nWeb Endpoints:" -ForegroundColor Cyan
    foreach ($endpoint in $checks.WebEndpoints) {
        $status = "FAIL"
        $detail = ""
        try {
            $response = Invoke-WebRequest -Uri $endpoint.Url -Method HEAD -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            if ($response.StatusCode -eq $endpoint.ExpectedStatus) {
                $status = "PASS"
                $detail = "HTTP $($response.StatusCode)"
            }
            else {
                $detail = "HTTP $($response.StatusCode) (expected $($endpoint.ExpectedStatus))"
            }
        }
        catch {
            $detail = $_.Exception.Message
        }

        $color = if ($status -eq "PASS") { "Green" } else { "Red" }
        Write-Host "  [$status] $($endpoint.Name) — $detail" -ForegroundColor $color

        $results += [PSCustomObject]@{
            Type   = "Web"
            Name   = $endpoint.Name
            Status = $status
            Detail = $detail
            Time   = Get-Date -Format "HH:mm:ss"
        }
    }
}

# --- TCP Port Checks ---
if ($checks.TcpPorts) {
    Write-Host "`nTCP Ports:" -ForegroundColor Cyan
    foreach ($port in $checks.TcpPorts) {
        $status = "FAIL"
        $detail = ""
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connect = $tcp.BeginConnect($port.Host, $port.Port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne(5000, $false)
            if ($wait -and $tcp.Connected) {
                $status = "PASS"
                $detail = "Port $($port.Port) open"
            }
            else {
                $detail = "Port $($port.Port) timeout"
            }
            $tcp.Close()
        }
        catch {
            $detail = $_.Exception.Message
        }

        $color = if ($status -eq "PASS") { "Green" } else { "Red" }
        Write-Host "  [$status] $($port.Name) ($($port.Host):$($port.Port)) — $detail" -ForegroundColor $color

        $results += [PSCustomObject]@{
            Type   = "TCP"
            Name   = $port.Name
            Status = $status
            Detail = $detail
            Time   = Get-Date -Format "HH:mm:ss"
        }
    }
}

# --- Windows Service Checks ---
if ($checks.WindowsServices) {
    Write-Host "`nWindows Services:" -ForegroundColor Cyan
    foreach ($svc in $checks.WindowsServices) {
        $status = "FAIL"
        $detail = ""
        try {
            $service = Get-Service -Name $svc.ServiceName -ComputerName $svc.ComputerName -ErrorAction Stop
            if ($service.Status -eq "Running") {
                $status = "PASS"
                $detail = "Running"
            }
            else {
                $detail = $service.Status.ToString()
            }
        }
        catch {
            $detail = $_.Exception.Message
        }

        $color = if ($status -eq "PASS") { "Green" } else { "Red" }
        Write-Host "  [$status] $($svc.Name) — $detail" -ForegroundColor $color

        $results += [PSCustomObject]@{
            Type   = "Service"
            Name   = $svc.Name
            Status = $status
            Detail = $detail
            Time   = Get-Date -Format "HH:mm:ss"
        }
    }
}

# --- Summary ---
$passed = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$failed = ($results | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host "`nHealth Check Summary:" -ForegroundColor Yellow
Write-Host "  Passed: $passed | Failed: $failed | Total: $($results.Count)"

if ($failed -gt 0) {
    Write-Host "  ATTENTION: $failed service(s) failing!" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "  All services healthy." -ForegroundColor Green
    exit 0
}
