using namespace System.Net

param($Request, $TriggerMetadata)

# ===============================
# CONFIG
# ===============================
$OpenAIKey    = $env:OPENAI_API_KEY
$TeamsWebhook = $env:TEAMS_WEBHOOK_URL

# ===============================
# LOGGING
# ===============================
$TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[$TimeStamp] Webhook received"

# ===============================
# SAFE HELPER FUNCTION
# ===============================
function Get-FirstValue {
    param(
        [AllowNull()]
        [object[]]$Values,
        [string]$Default = "Unknown"
    )

    if ($null -eq $Values) {
        return $Default
    }

    foreach ($Value in $Values) {
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            return [string]$Value
        }
    }

    return $Default
}

# ===============================
# PARSE INPUT (SAFE)
# ===============================
$Body = $null
$RawString = ""

try {
    $RawString = $Request.Body

    if ($RawString -isnot [string]) {
        $RawString = $RawString | ConvertTo-Json -Depth 20
    }

    try {
        $Body = $RawString | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Host "[$TimeStamp] JSON parsing failed — using raw mode"
        $Body = @{}
    }
}
catch {
    Write-Host "[$TimeStamp] Request parsing failed"
    $Body = @{}
}

# ===============================
# EXTRACT DATA (SAFE)
# ===============================
$Tenant = Get-FirstValue @(
    $Body.Tenant,
    $Body.TaskInfo.Tenant,
    $Body.TaskInfo.Parameters.TenantFilter,
    $Body.TaskInfo.Parameters.options.HIDDEN_appliedDefaultsForTenant
) "Unknown Tenant"

$User = Get-FirstValue @(
    $Body.TaskInfo.Parameters.Username,
    $Body.User,
    $Body.user,
    $Body.UPN,
    $Body.username
) "Unknown User"

$Requester = Get-FirstValue @(
    $Body.TaskInfo.Parameters.Headers."x-ms-client-principal-name",
    $Body.Headers."x-ms-client-principal-name",
    $Body.RequestedBy,
    $Body.requestedBy,
    $Body.Actor,
    $Body.actor
) "Unknown"

$Action = Get-FirstValue @(
    $Body.TaskInfo.Name,
    $Body.TaskInfo.Command,
    $Body.Action,
    $Body.action,
    $Body.Event,
    $Body.event
) "Unknown Action"

# ===============================
# RESULTS HANDLING
# ===============================
$ResultsArray = @()

if ($Body.Results) {
    foreach ($r in $Body.Results) {
        if ($r.Results) {
            $ResultsArray += $r.Results
        }
    }
}

# ===============================
# STATUS LOGIC
# ===============================
$Success = ($ResultsArray | Where-Object { $_ -match "Successfully|Scheduled|Added" }).Count
$Fail    = ($ResultsArray | Where-Object { $_ -match "Failed|Error|Unable|Could not" }).Count

if ($Success -gt 0 -and $Fail -gt 0) {
    $FinalStatus = "Partial"
}
elseif ($Fail -gt 0) {
    $FinalStatus = "Failed"
}
elseif ($Success -gt 0) {
    $FinalStatus = "Success"
}
else {
    $FinalStatus = "Unknown"
}

Write-Host "[$TimeStamp] Status: $FinalStatus"

# ===============================
# AI SUMMARIZATION
# ===============================
$Summary = ""

try {
    if (-not $OpenAIKey) {
        throw "Missing OpenAI key"
    }

    $Prompt = @"
Summarize this MSP automation event clearly.

Tenant: $Tenant
User: $User
Requested By: $Requester
Action: $Action
Status: $FinalStatus

Results:
$($ResultsArray -join "`n")

Format clean for Microsoft Teams.
"@

    $RequestBody = @{
        model = "gpt-4o-mini"
        messages = @(
            @{ role = "user"; content = $Prompt }
        )
        temperature = 0.2
    } | ConvertTo-Json -Depth 5

    $Response = Invoke-RestMethod `
        -Uri "https://api.openai.com/v1/chat/completions" `
        -Headers @{
            Authorization = "Bearer $OpenAIKey"
            "Content-Type" = "application/json"
        } `
        -Method POST `
        -Body $RequestBody

    $Summary = $Response.choices[0].message.content
    Write-Host "[$TimeStamp] AI success"
}
catch {
    Write-Host "[$TimeStamp] AI failed — fallback"

    $Summary = @"
CIPP Event

Tenant: $Tenant
User: $User
Requested By: $Requester
Action: $Action
Status: $FinalStatus

Results:
$($ResultsArray -join "`n")
"@
}

# ===============================
# SEND TO TEAMS
# ===============================
try {
    $TeamsBody = @{
        text = $Summary
    } | ConvertTo-Json

    Invoke-RestMethod -Method POST -Uri $TeamsWebhook -Body $TeamsBody -ContentType "application/json"

    Write-Host "[$TimeStamp] Sent to Teams"
}
catch {
    Write-Host "[$TimeStamp] Teams send failed"
}

# ===============================
# RESPONSE
# ===============================
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = 200
    Body = "Processed"
})
