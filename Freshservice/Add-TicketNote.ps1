<#
.SYNOPSIS
    Adds a private or public note to a Freshservice ticket.

.DESCRIPTION
    Posts a note to an existing ticket via the Freshservice REST API.
    Supports both private (internal) and public (visible to requester) notes.

.PARAMETER TicketId
    The ticket number to add the note to.

.PARAMETER Body
    The note content. Plain text — will be wrapped in HTML paragraph tags.

.PARAMETER Public
    If specified, the note will be visible to the requester. Default is private.

.EXAMPLE
    .\Add-TicketNote.ps1 -TicketId 95496 -Body "Updated firmware and rebooted device."

.EXAMPLE
    .\Add-TicketNote.ps1 -TicketId 95496 -Body "Please try again and let us know." -Public
#>

param(
    [Parameter(Mandatory)]
    [int]$TicketId,

    [Parameter(Mandatory)]
    [string]$Body,

    [switch]$Public
)

# --- Configuration (update these) ---
$freshDomain = "YOUR_DOMAIN.freshservice.com"
$apiKey      = "YOUR_API_KEY"

# Basic auth
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${apiKey}:X"))
$headers = @{
    Authorization  = "Basic $base64Auth"
    "Content-Type" = "application/json"
}

$baseUrl = "https://$freshDomain/api/v2"

# --- Format Body ---
$htmlBody = "<p>" + ($Body -replace "`n", "<br>") + "</p>"

# --- Post Note ---
$isPrivate = -not $Public

$notePayload = @{
    body    = $htmlBody
    private = $isPrivate
} | ConvertTo-Json

Write-Host "Adding $( if ($isPrivate) { 'private' } else { 'public' } ) note to ticket #$TicketId..." -ForegroundColor Cyan

try {
    $response = Invoke-RestMethod -Uri "$baseUrl/tickets/$TicketId/notes" `
        -Headers $headers -Method POST -Body $notePayload

    Write-Host "Note added successfully." -ForegroundColor Green
    Write-Host "Note ID: $($response.conversation.id)" -ForegroundColor Gray
}
catch {
    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        Write-Host $reader.ReadToEnd() -ForegroundColor Red
    }
}
