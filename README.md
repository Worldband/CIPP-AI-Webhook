# CIPP AI Webhook

Azure Function PowerShell HTTP trigger that receives CIPP webhook alerts, normalizes the payload, summarizes it with OpenAI, and posts a clean alert to Microsoft Teams.

## Architecture

CIPP webhook -> Azure Function -> OpenAI -> Teams Incoming Webhook

## Required Azure Function environment variables

| Name | Purpose |
|---|---|
| `TEAMS_WEBHOOK_URL` | Full Teams incoming webhook URL |
| `OPENAI_API_KEY` | OpenAI API key |

## Optional environment variables

| Name | Default | Purpose |
|---|---:|---|
| `OPENAI_MODEL` | `gpt-4o-mini` | OpenAI model used for summaries |
| `OPENAI_MAX_TOKENS` | `350` | Max output tokens |

## Deploy

Create a Windows Consumption Azure Function App using PowerShell runtime.

Function name: `webhook`

Files:
- `function/run.ps1`
- `function/function.json`

You can paste `run.ps1` into the Azure portal editor, or deploy using Core Tools.

## Test with PowerShell

```powershell
Invoke-RestMethod -Method POST `
  -Uri "https://YOUR-FUNCTION.azurewebsites.net/api/webhook?code=FUNCTION_KEY" `
  -ContentType "application/json" `
  -Body (Get-Content .\samples\offboarding-partial.json -Raw)
```

## Status logic

The script calculates event status before sending to AI:

| Result mix | Status |
|---|---|
| Successes only | Success |
| Failures only | Failed |
| Both success and failure | Partial |
| Notes only | Informational |
| Unknown | Original CIPP status or Unknown |

Informational items such as "No MFA methods found" and "No mailbox permissions found" are treated as notes, not failures.

## Security

Do not hardcode secrets. Use Azure Function App environment variables.
