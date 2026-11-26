<#
.SYNOPSIS
    Read-only test: can this VDI + your login reach the ServiceNow API?
    Changes NOTHING in ServiceNow - it only reads one incident.
    If this works, the full ServiceNow link-up can be built.
    If it fails with 401/403, your account needs API permission (ask your lead / IT).

    Instance: https://your-instance.service-now.com
#>

# ServiceNow needs TLS 1.2 - make sure PowerShell uses it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Instance = "https://your-instance.service-now.com"

Write-Host ""
Write-Host "ServiceNow API test (read-only - changes nothing)" -ForegroundColor Cyan
Write-Host "Instance: $Instance"
Write-Host ""

$inc = Read-Host "Enter an incident number to look up (press Enter for INC0000000)"
if ([string]::IsNullOrWhiteSpace($inc)) { $inc = "INC0000000" }
$inc = $inc.Trim()

Write-Host ""
Write-Host "A login box will pop up - enter your ServiceNow username and password."
Write-Host "(This is only used for this test. Nothing is saved to a file.)"
$cred = Get-Credential -Message "ServiceNow login for $Instance"
if ($null -eq $cred) {
    Write-Host "No login entered - stopping."
    exit 1
}

$uri = "$Instance/api/now/table/incident?sysparm_query=number%3D$inc&sysparm_fields=number,short_description,caller_id,state,assigned_to&sysparm_limit=1"
try {
    $result = Invoke-RestMethod -Uri $uri -Credential $cred -Method Get -ErrorAction Stop
    if ($result.result.Count -eq 0) {
        Write-Host ""
        Write-Host "API WORKS - but no incident found with number $inc." -ForegroundColor Green
        Write-Host "Try a different INC number. The connection and your login are fine."
    }
    else {
        $ticket = $result.result[0]
        Write-Host ""
        Write-Host "API WORKS - ticket found:" -ForegroundColor Green
        Write-Host "  Number:           $($ticket.number)"
        Write-Host "  Short description: $($ticket.short_description)"
        Write-Host "  State:            $($ticket.state)"
        Write-Host "  Caller (sys_id):  $($ticket.caller_id.value)"
        Write-Host ""
        Write-Host "Next step: the full ServiceNow link-up can be built on this."
    }
}
catch {
    $status = $null
    if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    Write-Host ""
    if ($status -eq 401) {
        Write-Host "Got a 401 (unauthorized)." -ForegroundColor Red
        Write-Host "Either the username/password was wrong, or this ServiceNow"
        Write-Host "does not allow basic login for the API (it may use single sign-on)."
        Write-Host "Try again making sure the password is right. If it still fails,"
        Write-Host "ask your lead / IT whether REST API basic auth is allowed for your account."
    }
    elseif ($status -eq 403) {
        Write-Host "Got a 403 (forbidden)." -ForegroundColor Red
        Write-Host "Your login works, but your account does not have permission to"
        Write-Host "use the API. Ask your lead / IT to enable REST API access for your account."
    }
    else {
        Write-Host "API call failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($null -ne $status) { Write-Host "Status code: $status" }
    }
}
