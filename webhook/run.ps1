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
# SAFE HELPER FUNCTIONS
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
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    try {
        if ($Value -is [string]) {
            return $Value
        }

        return ($Value | ConvertTo-Json -Depth 20 -Compress)
    }
    catch {
        return [string]$Value
    }
}

# ===============================
# PARSE INPUT SAFELY
# ===============================
$Body = $null
$RawString = ""

try {
    $RawString = Convert-ToSafeString -Value $Request.Body

    if ([string]::IsNullOrWhiteSpace($RawString)) {
        $RawString = "{}"
    }

    try {
        $Body = $RawString | ConvertFrom-Json -ErrorAction Stop
        Write-Host "[$TimeStamp] JSON parsed successfully"
    }
    catch {
        Write-Host "[$TimeStamp] JSON parsing failed. Attempting basic repair."

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
            Write-Host "[$TimeStamp] JSON repair failed. Continuing in raw text mode."
            $Body = [pscustomobject]@{
                raw = $RawString
            }
        }
    }
}
catch {
    Write-Host "[$TimeStamp] Request parsing failed. Continuing with empty body."
    $Body = [pscustomobject]@{
        raw = ""
    }
}

# ===============================
# EXTRACT DATA SAFELY
# Supports CIPP scheduled task payloads, CIPP logbook alerts, Teams command payloads, and raw text.
# ===============================
$Tenant = Get-FirstValue -Values @(
    $Body.Tenant,
    $Body.tenant,
    $Body.CustomerTenant,
    $Body.customerTenant,
    $Body.TaskInfo.Tenant,
    $Body.TaskInfo.Parameters.TenantFilter,
    $Body.TaskInfo.Parameters.options.HIDDEN_appliedDefaultsForTenant
) -Default "Unknown Tenant"

$User = Get-FirstValue -Values @(
    $Body.TaskInfo.Parameters.Username,
    $Body.User,
    $Body.user,
    $Body.UPN,
    $Body.upn,
    $Body.Username,
    $Body.username,
    $Body.TargetUser,
    $Body.targetUser
) -Default "Unknown User"

$Requester = Get-FirstValue -Values @(
    $Body.TaskInfo.Parameters.Headers."x-ms-client-principal-name",
    $Body.Headers."x-ms-client-principal-name",
    $Body.RequestedBy,
    $Body.requestedBy,
    $Body.Actor,
    $Body.actor,
    $Body.InitiatedBy,
    $Body.initiatedBy,
    $Body.User,
    $Body.user
) -Default "Unknown"

$Action = Get-FirstValue -Values @(
    $Body.TaskInfo.Name,
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

$Message = Get-FirstValue -Values @(
    $Body.Message,
    $Body.message,
    $Body.Text,
    $Body.text,
    $Body.body,
    $Body.TaskInfo.Results,
    $Body.raw
) -Default "No specific results available"

# ===============================
# TEAMS COMMAND DETECTION
# ===============================
$IsTeamsCommand = $false
$TeamsCommandText = Get-FirstValue -Values @(
    $Body.message,
    $Body.text,
    $Body.Text,
    $Body.body
) -Default ""

if (-not [string]::IsNullOrWhiteSpace($TeamsCommandText)) {
    $IsTeamsCommand = $true
    $Action = "Teams Command"
    $Message = $TeamsCommandText

    if ($TeamsCommandText -match '(?i)\boffboard\s+user\s+([^\s<]+)') {
        $Action = "Offboarding Request"
        $User = $Matches[1]
    }
    elseif ($TeamsCommandText -match '(?i)\boffboard\s+([^\s<]+)') {
        $Action = "Offboarding Request"
        $User = $Matches[1]
    }
}

# ===============================
# RESULTS HANDLING
# ===============================
$ResultsArray = @()

if ($Body.Results) {
    if ($Body.Results -is [string]) {
        $ResultsArray += $Body.Results
    }
    else {
        foreach ($ResultItem in $Body.Results) {
            $ResultText = Get-FirstValue -Values @(
                $ResultItem.Results,
                $ResultItem.Message,
                $ResultItem.message,
                $ResultItem.Result,
                $ResultItem.result,
                $ResultItem
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
    $ResultsArray += "No specific results available"
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
    "Hidden"
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
    "NotFound"
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
elseif ($IsTeamsCommand) {
    $FinalStatus = "Received"
}
else {
    $FinalStatus = "Unknown"
}

Write-Host "[$TimeStamp] Tenant: $Tenant"
Write-Host "[$TimeStamp] User: $User"
Write-Host "[$TimeStamp] Requested By: $Requester"
Write-Host "[$TimeStamp] Action: $Action"
Write-Host "[$TimeStamp] Status: $FinalStatus"

# ===============================
# AI SUMMARIZATION
# ===============================
$Summary = ""

try {
    if ([string]::IsNullOrWhiteSpace($OpenAIKey)) {
        throw "Missing OPENAI_API_KEY environment variable"
    }

    $Prompt = @"
You are an MSP automation assistant.

Analyze the raw incoming webhook or Teams command and create a clean Microsoft Teams message. Do not use emojis.

Important:
- Use the RAW INPUT as the source of truth.
- The parsed fields may be incomplete or Unknown.
- Do not invent facts.
- If this is a Teams command, summarize the request only. Do not claim the CIPP action was executed unless the input explicitly says it was executed.
- If the tenant can be inferred from the email domain, use the domain as the tenant.
- If the user can be inferred from the raw input, use that user.
- If the action can be inferred from the raw input, use that action.
- If information is missing, say what is missing.

Format exactly:

Title: <short title>

Tenant: <tenant or Unknown>
User: <target user or Unknown>
Requested By: <requester or Unknown>
Action: <action or Unknown>
Status: <status or Request Received>

Completed Actions:
- <completed item or None>

Issues:
- <issue item or None>

Notes:
- <important note or None>

RAW INPUT:
$RawString

Parsed Fields:
Tenant: $Tenant
User: $User
Requested By: $Requester
Action: $Action
Status: $FinalStatus

Results:
$($ResultsArray -join "`n")
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
        max_tokens = 500
    } | ConvertTo-Json -Depth 10

    $OpenAIResponse = Invoke-RestMethod `
        -Uri "https://api.openai.com/v1/chat/completions" `
        -Headers @{
            Authorization = "Bearer $OpenAIKey"
            "Content-Type" = "application/json"
        } `
        -Method POST `
        -Body $OpenAIRequest `
        -TimeoutSec 45

    $Summary = $OpenAIResponse.choices[0].message.content

    if ([string]::IsNullOrWhiteSpace($Summary)) {
        throw "OpenAI returned an empty response"
    }

    Write-Host "[$TimeStamp] OpenAI summarization succeeded"
}
catch {
    Write-Host "[$TimeStamp] OpenAI summarization failed. Using fallback. Error: $($_.Exception.Message)"

    $Summary = @"
Title: MSP Automation Event

Tenant: $Tenant
User: $User
Requested By: $Requester
Action: $Action
Status: $FinalStatus

Completed Actions:
$($ResultsArray -join "`n")

Issues:
None

Notes:
AI summarization failed. Review raw results above.
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
# RESPONSE
# ===============================
$ResponseBody = @{
    status = "processed"
    tenant = $Tenant
    user = $User
    requestedBy = $Requester
    action = $Action
    finalStatus = $FinalStatus
    message = $Summary
} | ConvertTo-Json -Depth 10

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = 200
    Body = $ResponseBody
    Headers = @{
        "Content-Type" = "application/json"
    }
})
