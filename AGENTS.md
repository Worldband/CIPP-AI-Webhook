# AGENTS.md

## Project

This repo maintains a PowerShell Azure Function used by Worldband to process CIPP webhook alerts, summarize them with OpenAI, and post clean messages to Microsoft Teams.

## Rules

- Never hardcode secrets.
- Use environment variables for `TEAMS_WEBHOOK_URL` and `OPENAI_API_KEY`.
- Do not use emojis in Teams output.
- Keep Teams output professional and technician-readable.
- Handle malformed CIPP payloads defensively.
- Prefer deterministic PowerShell logic for status classification.
- Use AI for summarization only, not for deciding critical business logic.
- Preserve Azure Functions PowerShell compatibility.
- Do not return HTTP 500 to CIPP unless unavoidable.
- Maintain a Teams fallback message if OpenAI fails.
- Status values should be limited to: `Success`, `Partial`, `Failed`, `Informational`, `Unknown`.
