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
Write-Host "[$TimeStamp] CIPP webhook received"

# ===============================
# HELPERS
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

function Convert-ToSafeString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    try {
        if ($Value -is [string]) {
            return $Value
        }

        return ($Value | ConvertTo-Json -Depth 30 -Compress)
    }
    catch {
        return [string]$Value
    }
}

# ===============================
# PARSE CIPP PAYLOAD SAFELY
# ===============================
$Body = $null
$RawString = ""

try {
    $RawString = Convert-ToSafeString -Value $Request.Body

    if ([string]::IsNullOrWhiteSpace($RawString)) {
        throw "Empty request body"
    }

    try {
        $Body = $RawString | ConvertFrom-Json -ErrorAction Stop
        Write-Host "[$TimeStamp] JSON parsed successfully"
    }
    catch {
        Write-Host "[$TimeStamp] JSON parsing failed. Attempting repair."

        try {
            $FixedJson = $RawString `
                -replace "'", '"' `
                -replace ':\s*,', ': null,' `
                -replace ',\s*}', '}' `
                -replace ',\s*]', ']'

            $Body = $FixedJson | ConvertFrom-Json -ErrorAction Stop
            Write-Host "[$TimeStamp] JSON repair succeeded"
        }
        catch {
            Write-Host "[$TimeStamp] JSON repair failed. Using raw text mode."

            $Body = [pscustomobject]@{
                raw = $RawString
            }
        }
    }
}
catch {
    Write-Host "[$TimeStamp] Failed to read request body. Error: $($_.Exception.Message)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 400
        Body       = "Invalid request body"
    })
    return
}


# ===============================
# NORMALIZE WRAPPED CIPP PAYLOAD
# ===============================
$CippEvent = $Body

try {
    if ($Body.payload -and $Body.payload.Count -gt 0) {
        $CippEvent = $Body.payload[0]
        Write-Host "[$TimeStamp] Detected wrapped CIPP payload format"
    }
}
catch {
    $CippEvent = $Body
}

# ===============================
# EXTRACT CIPP DATA
# ===============================
$Tenant = Get-FirstValue -Values @(
    $Body.Tenant,
    $Body.tenant,
    $CippEvent.Tenant,
    $CippEvent.tenant,
    $Body.tenant,
    $CippEvent.TaskInfo.Tenant,
    $CippEvent.task.Tenant,
    $Body.TaskInfo.Tenant,
    $CippEvent.TaskInfo.Parameters.TenantFilter,
    $CippEvent.task.Parameters.TenantFilter,
    $Body.TaskInfo.Parameters.TenantFilter,
    $CippEvent.TaskInfo.Parameters.options.HIDDEN_appliedDefaultsForTenant,
    $CippEvent.task.Parameters.options.HIDDEN_appliedDefaultsForTenant,
    $Body.TaskInfo.Parameters.options.HIDDEN_appliedDefaultsForTenant
) -Default "Unknown Tenant"

$TargetUser = Get-FirstValue -Values @(
    $CippEvent.TaskInfo.Parameters.Username,
    $CippEvent.task.Parameters.Username,
    $CippEvent.task.user,
    $CippEvent.user,
    $Body.TaskInfo.Parameters.Username,
    $Body.Username,
    $Body.username,
    $Body.User,
    $Body.user,
    $Body.UPN,
    $Body.upn,
    $Body.TargetUser,
    $Body.targetUser
) -Default "Unknown User"

$RequestedBy = Get-FirstValue -Values @(
    $CippEvent.TaskInfo.Parameters.Headers."x-ms-client-principal-name",
    $CippEvent.task.Parameters.Headers."x-ms-client-principal-name",
    $CippEvent.Headers."x-ms-client-principal-name",
    $Body.TaskInfo.Parameters.Headers."x-ms-client-principal-name",
    $Body.Headers."x-ms-client-principal-name",
    $CippEvent.RequestedBy,
    $CippEvent.requestedBy,
    $Body.RequestedBy,
    $Body.requestedBy,
    $CippEvent.Actor,
    $CippEvent.actor,
    $Body.Actor,
    $Body.actor,
    $CippEvent.InitiatedBy,
    $CippEvent.initiatedBy,
    $Body.InitiatedBy,
    $Body.initiatedBy
) -Default "Unknown"

$Action = Get-FirstValue -Values @(
    $CippEvent.TaskInfo.Name,
    $CippEvent.task.Name,
    $CippEvent.task.name,
    $Body.TaskInfo.Name,
    $CippEvent.TaskInfo.Command,
    $CippEvent.task.Command,
    $CippEvent.task.command,
    $Body.TaskInfo.Command,
    $Body.Action,
    $Body.action,
    $Body.API,
    $Body.api,
    $Body.Event,
    $Body.event,
    $Body.Operation,
    $Body.operation
) -Default "Unknown Action"

$TaskState = Get-FirstValue -Values @(
    $CippEvent.TaskInfo.TaskState,
    $CippEvent.task.TaskState,
    $CippEvent.task.state,
    $Body.TaskInfo.TaskState,
    $Body.TaskState,
    $Body.status,
    $Body.Status,
    $Body.TaskInfo.Results,
    $Body.Results
) -Default "Unknown"

$CippReference = Get-FirstValue -Values @(
    $CippEvent.TaskInfo.RowKey,
    $CippEvent.task.RowKey,
    $CippEvent.task.id,
    $Body.TaskInfo.RowKey,
    $Body.TaskInfo.Reference,
    $Body.Reference,
    $Body.RowKey,
    $Body.id,
    $Body.Id
) -Default ""

$Message = Get-FirstValue -Values @(
    $Body.Message,
    $Body.message,
    $Body.Text,
    $Body.text,
    $Body.TaskInfo.Results,
    $Body.raw
) -Default ""

# Infer target user from action/title when CIPP wrapped payload does not expose username separately
if ($TargetUser -eq "Unknown User") {
    if ($Action -match '(?i)offboarding:\s*([^\s]+@[^\s]+)') {
        $TargetUser = $Matches[1]
    }
    elseif ($RawString -match '(?i)offboarding:\s*([^\s",]+@[^\s",]+)') {
        $TargetUser = $Matches[1]
    }
}

# Make missing requester explicit instead of looking like a parsing failure
if ($RequestedBy -eq "Unknown") {
    $RequestedBy = "Not included in CIPP payload"
}

# ===============================
# RESULT COLLECTION
# ===============================
$ResultsArray = @()

if ($CippEvent.results) {
    $BodyResults = $CippEvent.results
}
elseif ($CippEvent.Results) {
    $BodyResults = $CippEvent.Results
}
else {
    $BodyResults = $Body.Results
}

if ($BodyResults) {
    if ($BodyResults -is [string]) {
        $ResultsArray += $BodyResults
    }
    else {
        foreach ($ResultItem in $BodyResults) {
            $ResultText = Get-FirstValue -Values @(
                $ResultItem.Results,
                $ResultItem.Message,
                $ResultItem.message,
                $ResultItem.Result,
                $ResultItem.result
            ) -Default ""

            if (-not [string]::IsNullOrWhiteSpace($ResultText)) {
                $ResultsArray += $ResultText
            }
        }
    }
}

if ($ResultsArray.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Message)) {
    $ResultsArray += $Message
}

if ($ResultsArray.Count -eq 0) {
    $ResultsArray += "No specific results were included in the CIPP payload."
}

# ===============================
# STATUS LOGIC
# ===============================
$SuccessPatterns = @(
    "Successfully",
    "Success",
    "Scheduled",
    "Added",
    "Completed",
    "Executed",
    "Updated",
    "Removed",
    "Revoked",
    "Converted",
    "Hidden",
    "Set "
)

$FailurePatterns = @(
    "Failed",
    "Error",
    "Unable",
    "Could not",
    "Cannot",
    "Exception",
    "Denied",
    "Unauthorized",
    "Not found",
    "NotFound",
    "couldn't be found"
)

$SuccessCount = 0
$FailureCount = 0

foreach ($Line in $ResultsArray) {
    foreach ($Pattern in $SuccessPatterns) {
        if ($Line -match $Pattern) {
            $SuccessCount++
            break
        }
    }

    foreach ($Pattern in $FailurePatterns) {
        if ($Line -match $Pattern) {
            $FailureCount++
            break
        }
    }
}

if ($SuccessCount -gt 0 -and $FailureCount -gt 0) {
    $FinalStatus = "Partial"
}
elseif ($FailureCount -gt 0) {
    $FinalStatus = "Failed"
}
elseif ($SuccessCount -gt 0) {
    $FinalStatus = "Success"
}
else {
    $FinalStatus = $TaskState
}

Write-Host "[$TimeStamp] Tenant: $Tenant"
Write-Host "[$TimeStamp] Target User: $TargetUser"
Write-Host "[$TimeStamp] Requested By: $RequestedBy"
Write-Host "[$TimeStamp] Action: $Action"
Write-Host "[$TimeStamp] Status: $FinalStatus"

# ===============================
# RAW PAYLOAD REFERENCE
# ===============================
$PayloadPreview = ""

try {
    $PayloadPreview = $RawString

    if ($PayloadPreview.Length -gt 2000) {
        $PayloadPreview = $PayloadPreview.Substring(0, 2000) + "... [truncated]"
    }

    $PayloadPreview = $PayloadPreview -replace "`r", "" -replace "`n", " "
}
catch {
    $PayloadPreview = "Raw payload preview unavailable"
}


# ===============================
# OPENAI SUMMARY
# ===============================
$Summary = ""

try {
    if ([string]::IsNullOrWhiteSpace($OpenAIKey)) {
        throw "Missing OPENAI_API_KEY environment variable"
    }

    $Prompt = @"
You are an MSP automation assistant.

Create a clean, professional Microsoft Teams message for a CIPP webhook event. Do not use emojis.

Rules:
- Use the CIPP payload and extracted fields as the source of truth.
- Do not invent facts.
- Keep the message concise and useful for technicians.
- Status must be exactly: Success, Partial, Failed, Unknown, or the provided CIPP task state.
- If there are both successful and failed actions, status must be Partial.
- Separate completed actions from issues.
- Treat "No MFA methods found" and "not a member of any groups" as notes, not failures.
- Do not repeat the target user in every bullet. Since the entire event is already for the target user, write short bullets like "Disabled sign-in", "Revoked sessions", "Scheduled license removal".
- Do not include long Exchange server names, GUIDs, or backend exception noise unless needed to understand the issue.
- Compress duplicate mailbox permission failures into one summarized issue.
- Keep Completed Actions to the most important 8 items maximum.
- Keep Issues to the most important 8 items maximum.
- If Requested By is "Not included in CIPP payload", keep that exact wording.
- At the bottom, if CIPP Reference exists, include: Reference: <value>
- Do not include the raw payload preview in the main AI summary. It is appended separately by the script.

Format exactly:

Title: <short title>

Tenant: <tenant>
User: <target user>
Requested By: <requester>
Action: <action>
Status: <status>

Completed Actions:
- <item or None>

Issues:
- <item or None>

Notes:
- <item or None>

Reference:
<reference or None>

Extracted Fields:
Tenant: $Tenant
User: $TargetUser
Requested By: $RequestedBy
Action: $Action
Status: $FinalStatus
CIPP Reference: $CippReference

Results:
$($ResultsArray -join "`n")

Raw Payload Preview:
$RawString
"@

    $OpenAIRequest = @{
        model = "gpt-4o-mini"
        messages = @(
            @{
                role = "user"
                content = $Prompt
            }
        )
        temperature = 0.2
        max_tokens = 700
    } | ConvertTo-Json -Depth 10

    $OpenAIResponse = Invoke-RestMethod `
        -Uri "https://api.openai.com/v1/chat/completions" `
        -Headers @{
            Authorization  = "Bearer $OpenAIKey"
            "Content-Type" = "application/json"
        } `
        -Method POST `
        -Body $OpenAIRequest `
        -TimeoutSec 45

    $Summary = $OpenAIResponse.choices[0].message.content

    if ([string]::IsNullOrWhiteSpace($Summary)) {
        throw "OpenAI returned an empty response"
    }

    if (-not [string]::IsNullOrWhiteSpace($PayloadPreview)) {
        $Summary += "`n`nReference Payload Preview:`n$PayloadPreview"
    }

    Write-Host "[$TimeStamp] OpenAI summarization succeeded"
}
catch {
    Write-Host "[$TimeStamp] OpenAI summarization failed. Using fallback. Error: $($_.Exception.Message)"

    $Summary = @"
Title: CIPP Automation Event

Tenant: $Tenant
User: $TargetUser
Requested By: $RequestedBy
Action: $Action
Status: $FinalStatus

Completed Actions:
$($ResultsArray -join "`n")

Issues:
Review the results above for any failed actions.

Notes:
AI summarization failed. This is fallback output.

Reference:
$CippReference

Reference Payload Preview:
$PayloadPreview
"@
}

# ===============================
# SEND TO TEAMS
# ===============================
try {
    if ([string]::IsNullOrWhiteSpace($TeamsWebhook)) {
        throw "Missing TEAMS_WEBHOOK_URL environment variable"
    }

    $TeamsBody = @{
        text = $Summary
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Method POST `
        -Uri $TeamsWebhook `
        -Body $TeamsBody `
        -ContentType "application/json" `
        -TimeoutSec 30

    Write-Host "[$TimeStamp] Sent to Teams"
}
catch {
    Write-Host "[$TimeStamp] Teams send failed. Error: $($_.Exception.Message)"
}

# ===============================
# RESPONSE TO CIPP
# ===============================
$ResponseBody = @{
    status       = "processed"
    tenant       = $Tenant
    user         = $TargetUser
    requestedBy  = $RequestedBy
    action       = $Action
    finalStatus  = $FinalStatus
    reference    = $CippReference
} | ConvertTo-Json -Depth 10

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = 200
    Body       = $ResponseBody
    Headers    = @{
        "Content-Type" = "application/json"
    }
})
