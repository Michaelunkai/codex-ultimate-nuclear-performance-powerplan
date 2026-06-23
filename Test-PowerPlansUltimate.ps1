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

'PASS'
