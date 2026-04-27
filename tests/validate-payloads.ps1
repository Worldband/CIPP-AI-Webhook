param(
    [string]$SamplePath = ".\samples\offboarding-partial.json"
)

if (-not (Test-Path $SamplePath)) {
    throw "Sample not found: $SamplePath"
}

$content = Get-Content $SamplePath -Raw

try {
    $null = $content | ConvertFrom-Json -ErrorAction Stop
    Write-Host "VALID JSON: $SamplePath"
}
catch {
    Write-Host "INVALID JSON: $SamplePath"
    Write-Host $_.Exception.Message
    exit 1
}
