<#
.SYNOPSIS
    Grants (or removes) the two narrow permissions the Jenkins job
    AFD-Certificate-Auto-Revalidation needs. TEST SCOPE: example.ca / .com only.

.DESCRIPTION
    Run by someone with OWNER on subscription YOUR_SUBSCRIPTION_ID (Contributor cannot
    create roles or assignments). Needs az CLI, signed in as that account.

    Creates 2 custom roles (if not already there) from the JSON files beside this
    script, then 4 role assignments for service principal your-automation-app:

      AFD Validation Token Refresher (Jenkins)
        -> frontdoor-profile-a / customdomains / example-ca
        -> frontdoor-profile-a / customdomains / example-com
         (custom-domain level, NOT the profile - the profile may hold other domains)

      DNS TXT Record Writer (Jenkins)
        -> RG-DNS / example.ca  / TXT / _dnsauth
        -> RG-DNS / example.com / TXT / _dnsauth
         (record-set level - cannot touch SPF, MX, or any other record)

    The app already has Reader on the subscription; nothing else changes.

.PARAMETER Remove
    Back-out: deletes the 4 assignments, then the 2 custom roles.

.EXAMPLE
    .\Grant-AutoRevalidationPermissions.ps1
    .\Grant-AutoRevalidationPermissions.ps1 -Remove
#>
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$sub    = 'YOUR_SUBSCRIPTION_ID'
$spId   = 'YOUR_SERVICE_PRINCIPAL_OBJECT_ID'      # your-automation-app (object id)
$afdRole = 'AFD Validation Token Refresher (Jenkins)'
$dnsRole = 'DNS TXT Record Writer (Jenkins)'

$fd  = "/subscriptions/$sub/resourceGroups/RG-FRONTDOOR-A/providers/Microsoft.Cdn/profiles/frontdoor-profile-a/customdomains"
$dns = "/subscriptions/$sub/resourceGroups/RG-DNS/providers/Microsoft.Network/dnszones"

$assignments = @(
    @{ Role = $afdRole; Scope = "$fd/example-ca"  },
    @{ Role = $afdRole; Scope = "$fd/example-com" },
    @{ Role = $dnsRole; Scope = "$dns/example.ca/TXT/_dnsauth"  },
    @{ Role = $dnsRole; Scope = "$dns/example.com/TXT/_dnsauth" }
)

az account set --subscription $sub
Write-Host "Signed in as: $(az account show --query user.name -o tsv)"
Write-Host ""

if ($Remove) {
    foreach ($a in $assignments) {
        Write-Host "Removing $($a.Role) at $($a.Scope)"
        az role assignment delete --assignee $spId --role $a.Role --scope $a.Scope 2>$null
    }
    foreach ($r in $afdRole, $dnsRole) {
        Write-Host "Deleting custom role $r"
        az role definition delete --name $r --custom-role-only true 2>$null
    }
    Write-Host "Done. The app is back to Reader only."
    return
}

# ---- 1. Custom roles (skip if they already exist) --------------------------------
foreach ($pair in @(@($afdRole, 'role-afd-validation-token-refresher.json'), @($dnsRole, 'role-dns-txt-record-writer.json'))) {
    $exists = az role definition list --name $pair[0] --custom-role-only true --query "[0].roleName" -o tsv
    if ($exists) {
        Write-Host "Role exists: $($pair[0])"
    } else {
        Write-Host "Creating role: $($pair[0])"
        az role definition create --role-definition "@$(Join-Path $PSScriptRoot $pair[1])" -o none
    }
}

# ---- 2. Assignments (new custom roles can take a minute or two to replicate) -----
foreach ($a in $assignments) {
    for ($try = 1; $try -le 10; $try++) {
        az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
            --role $a.Role --scope $a.Scope -o none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Assigned $($a.Role) -> $($a.Scope)"; break }
        if ($try -eq 10) { throw "Could not assign $($a.Role) at $($a.Scope)" }
        Write-Host "  role not visible yet, retrying in 30s ($try/10)"
        Start-Sleep -Seconds 30
    }
}

# ---- 3. Verify (az rest - 'az role assignment list' is unreliable here) ----------
Write-Host ""
Write-Host "Assignments now held by the app:"
az rest --method get `
    --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$spId'" `
    --query "value[].properties.scope" -o tsv
