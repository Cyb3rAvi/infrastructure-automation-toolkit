<#
.SYNOPSIS
    Retrieves ticket details and conversations from Freshservice.

.DESCRIPTION
    Pulls ticket info, notes, and replies using the Freshservice REST API.
    Displays a formatted summary with conversation history.

.PARAMETER TicketId
    The ticket number to retrieve (e.g., 12345 for INC-12345).

.EXAMPLE
    .\Get-TicketDetails.ps1 -TicketId 95496
    Displays full ticket details and conversation history.
#>

param(
    [Parameter(Mandatory)]
    [int]$TicketId
)

# --- Configuration (update these) ---
$freshDomain = "YOUR_DOMAIN.freshservice.com"
$apiKey      = "YOUR_API_KEY"

# Basic auth: API key as username, "X" as password
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${apiKey}:X"))
$headers = @{
    Authorization = "Basic $base64Auth"
    "Content-Type" = "application/json"
}

$baseUrl = "https://$freshDomain/api/v2"

# --- Get Ticket ---
Write-Host "Fetching ticket #$TicketId..." -ForegroundColor Cyan

try {
    $ticket = (Invoke-RestMethod -Uri "$baseUrl/tickets/$TicketId" -Headers $headers -Method GET).ticket
}
catch {
    Write-Host "Error fetching ticket: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Status mapping
$statusMap = @{ 2 = "Open"; 3 = "Pending"; 4 = "Resolved"; 5 = "Closed" }
$priorityMap = @{ 1 = "Low"; 2 = "Medium"; 3 = "High"; 4 = "Urgent" }

Write-Host "`n===== Ticket #$TicketId =====" -ForegroundColor Yellow
Write-Host "Subject:    $($ticket.subject)"
Write-Host "Status:     $($statusMap[[int]$ticket.status])"
Write-Host "Priority:   $($priorityMap[[int]$ticket.priority])"
Write-Host "Requester:  $($ticket.requester_id)"
Write-Host "Created:    $($ticket.created_at)"
Write-Host "Updated:    $($ticket.updated_at)"

if ($ticket.description_text) {
    Write-Host "`n--- Description ---" -ForegroundColor Cyan
    Write-Host $ticket.description_text
}

# --- Get Conversations ---
Write-Host "`n--- Conversations ---" -ForegroundColor Cyan

try {
    $conversations = (Invoke-RestMethod -Uri "$baseUrl/tickets/$TicketId/conversations" -Headers $headers -Method GET).conversations
}
catch {
    Write-Host "Could not fetch conversations." -ForegroundColor Yellow
    $conversations = @()
}

if ($conversations.Count -eq 0) {
    Write-Host "No conversations found."
}
else {
    foreach ($conv in $conversations | Sort-Object created_at) {
        $type = if ($conv.incoming) { "Reply" } else { "Note" }
        $visibility = if ($conv.private) { "(Private)" } else { "(Public)" }

        Write-Host "`n[$type $visibility] $($conv.created_at)" -ForegroundColor Gray
        Write-Host "From: $($conv.from_email)"

        # Strip HTML tags for clean output
        $body = $conv.body_text
        if (-not $body) {
            $body = $conv.body -replace '<[^>]+>', '' -replace '&nbsp;', ' '
        }
        Write-Host $body
    }
}

Write-Host "`n===== End of Ticket =====" -ForegroundColor Yellow
