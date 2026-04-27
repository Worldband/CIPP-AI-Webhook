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
using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================
# Worldband - CIPP AI Webhook Formatter
# Purpose:
#   Receive CIPP webhook payloads, normalize/repair malformed JSON,
#   extract key MSP fields, determine deterministic event status,
#   summarize with OpenAI, and post a clean alert to Microsoft Teams.
#
# Required Function App environment variables:
#   TEAMS_WEBHOOK_URL
#   OPENAI_API_KEY
#
# Optional Function App environment variables:
#   OPENAI_MODEL      Default: gpt-4o-mini
#   OPENAI_MAX_TOKENS Default: 350
# ============================================================

# -------------------------------
# CONFIG
# -------------------------------
$TeamsWebhook = $env:TEAMS_WEBHOOK_URL
$OpenAIKey    = $env:OPENAI_API_KEY
$OpenAIModel  = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-4o-mini" }
$MaxTokens    = if ($env:OPENAI_MAX_TOKENS) { [int]$env:OPENAI_MAX_TOKENS } else { 350 }

# -------------------------------
# LOGGING
# -------------------------------
$TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-FunctionLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[$TimeStamp] $Message"
}

Write-FunctionLog "Webhook received"

# -------------------------------
# NORMALIZE REQUEST BODY
# -------------------------------
function ConvertTo-SafeString {
    param(
        [Parameter(Mandatory = $false)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return ""
    }

    if ($InputObject -is [string]) {
        return $InputObject
    }

    return ($InputObject | ConvertTo-Json -Depth 30 -Compress)
}

function Repair-CommonJsonIssues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $Fixed = $Text

    # Remove leading CIPP alert prose if present before the first JSON object.
    $FirstBrace = $Fixed.IndexOf("{")
    if ($FirstBrace -gt 0) {
        $Fixed = $Fixed.Substring($FirstBrace)
    }

    # Remove trailing "see less" or other text after the last closing brace.
    $LastBrace = $Fixed.LastIndexOf("}")
    if ($LastBrace -ge 0 -and $LastBrace -lt ($Fixed.Length - 1)) {
        $Fixed = $Fixed.Substring(0, $LastBrace + 1)
    }

    # Common CIPP/log formatting problems.
    $Fixed = $Fixed -replace ':\s*,', ': null,'
    $Fixed = $Fixed -replace ',\s*}', '}'
    $Fixed = $Fixed -replace ',\s*]', ']'

    # Remove problematic control characters while preserving normal whitespace.
    $Fixed = $Fixed -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', ' '

    return $Fixed
}

$RawString = ""
$Body = $null
$JsonParsed = $false

try {
    $RawString = ConvertTo-SafeString -InputObject $Request.Body

    if ([string]::IsNullOrWhiteSpace($RawString)) {
        throw "Empty request body"
    }

    try {
        $Body = $RawString | ConvertFrom-Json -ErrorAction Stop
        $JsonParsed = $true
        Write-FunctionLog "JSON parsed successfully"
    }
    catch {
        Write-FunctionLog "JSON malformed. Attempting repair."

        $FixedJson = Repair-CommonJsonIssues -Text $RawString
        $Body = $FixedJson | ConvertFrom-Json -ErrorAction Stop
        $RawString = $FixedJson
        $JsonParsed = $true
        Write-FunctionLog "JSON repair succeeded"
    }
}
catch {
    Write-FunctionLog "JSON parsing failed. Continuing in raw text mode. Error: $($_.Exception.Message)"

    $Body = [pscustomobject]@{
        raw = $RawString
    }
}

# -------------------------------
# SAFE PROPERTY HELPERS
# -------------------------------
function Get-FirstValue {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Values,

        [Parameter(Mandatory = $false)]
        [string]$Default = "Unknown"
    )

    foreach ($Value in $Values) {
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            return [string]$Value
        }
    }

    return $Default
}

function Get-ResultsLines {
    param(
        [Parameter(Mandatory = $false)]
        $Payload
    )

    $Lines = New-Object System.Collections.Generic.List[string]

    try {
        if ($Payload.Results) {
            foreach ($Item in $Payload.Results) {
                if ($Item.Results) {
                    [void]$Lines.Add([string]$Item.Results)
                }
                elseif ($Item -is [string]) {
                    [void]$Lines.Add([string]$Item)
                }
            }
        }
    }
    catch {
        # Keep fallback behavior quiet.
    }

    if ($Lines.Count -eq 0) {
        $RawPreview = ConvertTo-SafeString -InputObject $Payload
        if ($RawPreview.Length -gt 4000) {
            $RawPreview = $RawPreview.Substring(0, 4000)
        }
        [void]$Lines.Add($RawPreview)
    }

    return $Lines.ToArray()
}

# -------------------------------
# EXTRACT STRUCTURED CIPP DATA
# -------------------------------
$Tenant = Get-FirstValue -Values @(
    $Body.Tenant,
    $Body.TaskInfo.Tenant,
    $Body.TaskInfo.Parameters.TenantFilter,
    $Body.TaskInfo.Parameters.options.HIDDEN_appliedDefaultsForTenant
) -Default "Unknown Tenant"

$User = Get-FirstValue -Values @(
    $Body.TaskInfo.Parameters.Username,
    $Body.User,
    $Body.user,
    $Body.UPN,
    $Body.username
) -Default "Unknown User"

$Requester = Get-FirstValue -Values @(
    $Body.TaskInfo.Parameters.Headers."x-ms-client-principal-name",
    $Body.Headers."x-ms-client-principal-name",
    $Body.RequestedBy,
    $Body.requestedBy,
    $Body.Actor,
    $Body.actor
) -Default "Unknown"

$Action = Get-FirstValue -Values @(
    $Body.TaskInfo.Name,
    $Body.TaskInfo.Command,
    $Body.Action,
    $Body.action,
    $Body.Event,
    $Body.event
) -Default "Unknown Action"

$RawStatus = Get-FirstValue -Values @(
    $Body.TaskInfo.Results,
    $Body.TaskInfo.TaskState,
    $Body.Status,
    $Body.status,
    $Body.Result,
    $Body.result
) -Default "Unknown"

$ResultsArray = Get-ResultsLines -Payload $Body

# -------------------------------
# DETERMINISTIC STATUS LOGIC
# -------------------------------
$SuccessPatterns = @(
    "successfully",
    "scheduled",
    "added task",
    "completed",
    "converted",
    "revoked",
    "removed",
    "hidden",
    "set account enabled state"
)

$FailurePatterns = @(
    "failed",
    "error",
    "unable",
    "could not",
    "cannot",
    "not found",
    "does not exist",
    "couldn't be found",
    "not retriable"
)

$InfoPatterns = @(
    "no mfa methods found",
    "no mailbox permissions found",
    "not a member of any groups",
    "already removed",
    "already exists",
    "don't exist"
)

$SuccessCount = 0
$FailureCount = 0
$InfoCount = 0

foreach ($Line in $ResultsArray) {
    $LowerLine = ([string]$Line).ToLowerInvariant()

    $IsInfo = $false
    foreach ($Pattern in $InfoPatterns) {
        if ($LowerLine -like "*$Pattern*") {
            $InfoCount++
            $IsInfo = $true
            break
        }
    }

    if ($IsInfo) {
        continue
    }

    foreach ($Pattern in $FailurePatterns) {
        if ($LowerLine -like "*$Pattern*") {
            $FailureCount++
            break
        }
    }

    foreach ($Pattern in $SuccessPatterns) {
        if ($LowerLine -like "*$Pattern*") {
            $SuccessCount++
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
elseif ($InfoCount -gt 0) {
    $FinalStatus = "Informational"
}
else {
    $FinalStatus = $RawStatus
}

Write-FunctionLog "Tenant: $Tenant"
Write-FunctionLog "Target user: $User"
Write-FunctionLog "Requester: $Requester"
Write-FunctionLog "Action: $Action"
Write-FunctionLog "Calculated status: $FinalStatus"

# -------------------------------
# PREP AI INPUT
# -------------------------------
$ResultsText = ($ResultsArray -join "`n")
if ($ResultsText.Length -gt 7000) {
    $ResultsText = $ResultsText.Substring(0, 7000)
    Write-FunctionLog "Results trimmed for AI input"
}

$Prompt = @"
You are an MSP automation alert formatter.

Create a clean Microsoft Teams alert from this CIPP automation event.

Rules:
- Do not use emojis.
- Do not invent facts.
- Use the provided Status exactly. Do not change it.
- Treat "No MFA methods found", "No mailbox permissions found", "not a member of any groups", "already exists", and "already removed or does not exist" as notes, not failures.
- Keep it concise and technician-readable.
- Use this exact layout:

Title: <short title>

Tenant: <tenant>
User: <target user>
Requested By: <requester>
Action: <action>
Status: <status>

Completed Actions:
- <short bullets>

Issues:
- <short bullets, or "None">

Notes:
- <short bullets, or "None">

Data:
Tenant: $Tenant
User: $User
Requested By: $Requester
Action: $Action
Status: $FinalStatus
Original Status: $RawStatus

Results:
$ResultsText
"@

# -------------------------------
# OPENAI CALL WITH RETRY
# -------------------------------
$Summary = $null
$OpenAIError = $null
$MaxRetries = 3

for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++) {
    try {
        if ([string]::IsNullOrWhiteSpace($OpenAIKey)) {
            throw "OPENAI_API_KEY is missing"
        }

        $OpenAIRequest = @{
            model = $OpenAIModel
            messages = @(
                @{
                    role = "system"
                    content = "You format MSP automation alerts for Microsoft Teams. Do not use emojis."
                },
                @{
                    role = "user"
                    content = $Prompt
                }
            )
            temperature = 0.2
            max_tokens = $MaxTokens
        } | ConvertTo-Json -Depth 10 -Compress

        Write-FunctionLog "Sending to OpenAI. Attempt $Attempt of $MaxRetries."

        $AIResponse = Invoke-RestMethod `
            -Uri "https://api.openai.com/v1/chat/completions" `
            -Headers @{
                "Authorization" = "Bearer $OpenAIKey"
                "Content-Type"  = "application/json"
            } `
            -Method Post `
            -Body $OpenAIRequest `
            -TimeoutSec 45

        $Summary = $AIResponse.choices[0].message.content

        if ([string]::IsNullOrWhiteSpace($Summary)) {
            throw "OpenAI returned an empty response"
        }

        Write-FunctionLog "OpenAI summarization succeeded"
        break
    }
    catch {
        $OpenAIError = $_.Exception.Message
        Write-FunctionLog "OpenAI attempt $Attempt failed: $OpenAIError"

        if ($Attempt -lt $MaxRetries) {
            Start-Sleep -Seconds (2 * $Attempt)
        }
    }
}

# -------------------------------
# FALLBACK SUMMARY
# -------------------------------
if ([string]::IsNullOrWhiteSpace($Summary)) {
    $Summary = @"
Title: CIPP Automation Event

Tenant: $Tenant
User: $User
Requested By: $Requester
Action: $Action
Status: $FinalStatus

Completed Actions:
$(
    ($ResultsArray | Where-Object {
        $l = $_.ToLowerInvariant()
        ($l -match "successfully|scheduled|added task|converted|revoked|hidden|set account enabled state") -and
        ($l -notmatch "failed|error|could not|unable|cannot|not found")
    } | ForEach-Object { "- $_" }) -join "`n"
)

Issues:
$(
    ($ResultsArray | Where-Object {
        $l = $_.ToLowerInvariant()
        $l -match "failed|error|could not|unable|cannot|not found|couldn't be found"
    } | ForEach-Object { "- $_" }) -join "`n"
)

Notes:
$(
    ($ResultsArray | Where-Object {
        $l = $_.ToLowerInvariant()
        $l -match "no mfa methods found|no mailbox permissions found|not a member of any groups|already removed|already exists|don't exist"
    } | ForEach-Object { "- $_" }) -join "`n"
)

OpenAI Error:
$OpenAIError
"@
}

# -------------------------------
# SEND TO TEAMS
# -------------------------------
try {
    if ([string]::IsNullOrWhiteSpace($TeamsWebhook)) {
        throw "TEAMS_WEBHOOK_URL is missing"
    }

    $TeamsMessage = @{
        text = $Summary
    } | ConvertTo-Json -Depth 5 -Compress

    Invoke-RestMethod `
        -Method Post `
        -Uri $TeamsWebhook `
        -Body $TeamsMessage `
        -ContentType "application/json" `
        -TimeoutSec 30

    Write-FunctionLog "Sent to Teams"
}
catch {
    Write-FunctionLog "Failed to send to Teams: $($_.Exception.Message)"
}

# -------------------------------
# RESPONSE BACK TO CIPP
# -------------------------------
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = 200
    Body = @{
        status        = "processed"
        tenant        = $Tenant
        user          = $User
        requestedBy   = $Requester
        action        = $Action
        finalStatus   = $FinalStatus
        jsonParsed    = $JsonParsed
    } | ConvertTo-Json -Compress
})
