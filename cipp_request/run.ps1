using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function New-JsonResponse {
    param(
        [int]$StatusCode,
        [object]$Body
    )

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]$StatusCode
        Headers = @{
            "Content-Type" = "application/json"
        }
        Body = ($Body | ConvertTo-Json -Depth 30)
    })
}

try {
    Write-Host "Received CIPP request webhook."

    $ExpectedSecret = $env:WORLDBAND_WEBHOOK_SECRET

    if ([string]::IsNullOrWhiteSpace($ExpectedSecret)) {
        Write-Error "WORLDBAND_WEBHOOK_SECRET is not configured."

        New-JsonResponse -StatusCode 500 -Body @{
            accepted = $false
            status = "ServerMisconfigured"
            message = "Webhook secret is not configured on the Azure Function."
        }

        return
    }

    $ProvidedSecret = $null

    if ($Request.Headers.ContainsKey("x-worldband-secret")) {
        $ProvidedSecret = $Request.Headers["x-worldband-secret"]
    }

    if ($ProvidedSecret -ne $ExpectedSecret) {
        Write-Warning "Webhook rejected because the shared secret did not match."

        New-JsonResponse -StatusCode 401 -Body @{
            accepted = $false
            status = "Unauthorized"
            message = "Invalid webhook secret."
        }

        return
    }

    $Payload = $Request.Body

    if ($null -eq $Payload) {
        New-JsonResponse -StatusCode 400 -Body @{
            accepted = $false
            status = "BadRequest"
            message = "Request body must be valid JSON."
        }

        return
    }

    $RequiredFields = @(
        "source",
        "requestId",
        "tenant",
        "clientName",
        "requestedBy",
        "ticketNumber",
        "action",
        "targetType",
        "target",
        "reason"
    )

    $MissingFields = @()

    foreach ($Field in $RequiredFields) {
        if ($null -eq $Payload.$Field -or [string]::IsNullOrWhiteSpace([string]$Payload.$Field)) {
            $MissingFields += $Field
        }
    }

    if ($MissingFields.Count -gt 0) {
        New-JsonResponse -StatusCode 400 -Body @{
            accepted = $false
            status = "BadRequest"
            message = "Missing required fields."
            missingFields = $MissingFields
        }

        return
    }

    if (([string]$Payload.source).Trim().ToLower() -ne "cw-rmm") {
        New-JsonResponse -StatusCode 400 -Body @{
            accepted = $false
            status = "BadRequest"
            message = "Invalid source. Expected cw-rmm."
        }

        return
    }

    $AllowedTargetTypes = @(
        "user",
        "device",
        "group",
        "mailbox",
        "tenant"
    )

    $TargetType = ([string]$Payload.targetType).Trim().ToLower()

    if ($AllowedTargetTypes -notcontains $TargetType) {
        New-JsonResponse -StatusCode 400 -Body @{
            accepted = $false
            status = "BadRequest"
            message = "Unsupported targetType."
            allowedTargetTypes = $AllowedTargetTypes
        }

        return
    }

    $AllowedActions = @(
        "disable user account",
        "enable user account",
        "block sign-in",
        "unblock sign-in",
        "reset password",
        "convert mailbox to shared",
        "hide mailbox from gal",
        "add user to group",
        "remove user from group",
        "add shared mailbox permission",
        "remove shared mailbox permission",
        "sync intune device",
        "retire intune device"
    )

    $ActionKey = ([string]$Payload.action).Trim().ToLower()

    if ($AllowedActions -notcontains $ActionKey) {
        New-JsonResponse -StatusCode 400 -Body @{
            accepted = $false
            status = "UnsupportedAction"
            message = "The requested action is not currently allowed."
            requestedAction = $Payload.action
            allowedActions = $AllowedActions
        }

        return
    }

    $RequestSummary = [ordered]@{
        requestId = $Payload.requestId
        source = $Payload.source
        tenant = $Payload.tenant
        clientName = $Payload.clientName
        requestedBy = $Payload.requestedBy
        ticketNumber = $Payload.ticketNumber
        action = $Payload.action
        targetType = $TargetType
        target = $Payload.target
        reason = $Payload.reason
        dryRun = if ($null -ne $Payload.dryRun) { [bool]$Payload.dryRun } else { $false }
        receivedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Write-Host "Accepted pending CIPP request:"
    Write-Host ($RequestSummary | ConvertTo-Json -Depth 30)

    New-JsonResponse -StatusCode 202 -Body @{
        accepted = $true
        status = "PendingApprovalStub"
        message = "Request accepted. Approval and CIPP execution are not enabled yet."
        request = $RequestSummary
    }

    return
}
catch {
    Write-Error $_.Exception.Message

    New-JsonResponse -StatusCode 500 -Body @{
        accepted = $false
        status = "ServerError"
        message = $_.Exception.Message
    }

    return
}
