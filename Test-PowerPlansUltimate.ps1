$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'PowerPlansUltimate.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Missing script: $scriptPath"
}

$tokens = $null
$errors = $null
[void] [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $errors)
if ($errors.Count -gt 0) {
    $messages = ($errors | ForEach-Object { $_.Message }) -join '; '
    throw "Parser errors: $messages"
}

$output = & $scriptPath -Silent 2>&1 | Out-String
if ($output.Trim().Length -ne 0) {
    throw 'Silent mode produced output.'
}

$active = powercfg /list | Select-String 'Codex_Ultimate_Nuclear_Performance.*\*'
if (-not $active) {
    throw 'Codex_Ultimate_Nuclear_Performance is not active after silent apply.'
}

$guidPath = Join-Path $env:LOCALAPPDATA 'CodexPowerPlans\CodexUltimatePowerPlan.guid'
if (-not (Test-Path -LiteralPath $guidPath -PathType Leaf)) {
    throw "Missing persisted GUID file: $guidPath"
}

$persistedGuid = (Get-Content -LiteralPath $guidPath -Raw).Trim()
if ($persistedGuid -notmatch '^[a-fA-F0-9-]{36}$') {
    throw "Invalid persisted GUID: $persistedGuid"
}

if ($active.Line -notmatch [regex]::Escape($persistedGuid)) {
    throw "Active plan is not the persisted exact GUID: $persistedGuid"
}

'PASS'
