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

$installRoot = if ((Split-Path -Leaf $PSScriptRoot) -eq '.codex-powerplan-state') {
    Split-Path -Parent $PSScriptRoot
} else {
    $PSScriptRoot
}
$stateRoot = Join-Path $installRoot '.codex-powerplan-state'
$guidPath = Join-Path $stateRoot 'CodexUltimatePowerPlan.guid'
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

$expectedTasks = @(
    'Codex Ultimate Power Plan Boot Enforcer',
    'Codex Ultimate Power Plan Guard'
)

foreach ($taskName in $expectedTasks) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -ne 'Ready') {
        throw "Task is not ready: $taskName ($($task.State))"
    }
    if (-not $task.Settings.Enabled) {
        throw "Task is not enabled: $taskName"
    }
    if (-not $task.Settings.Hidden) {
        throw "Task is not hidden: $taskName"
    }
    if ($task.Actions[0].Execute -ne (Join-Path $env:WINDIR 'System32\wscript.exe')) {
        throw "Task does not use wscript.exe: $taskName"
    }
    if ($task.Actions[0].Arguments -notmatch '//B //Nologo') {
        throw "Task action is not no-popup mode: $taskName"
    }
    if ($task.Actions[0].Arguments -notmatch [regex]::Escape((Join-Path $stateRoot 'Apply-UltimatePowerPlan.vbs'))) {
        throw "Task action does not use script-local startup payload: $taskName"
    }
    if ($task.Principal.UserId -ne 'SYSTEM') {
        throw "Task does not run as SYSTEM: $taskName ($($task.Principal.UserId))"
    }
    if ($task.Principal.RunLevel -ne 'Highest') {
        throw "Task does not run at highest privilege: $taskName ($($task.Principal.RunLevel))"
    }
}

$staleLogonTask = Get-ScheduledTask -TaskName 'Codex Ultimate Power Plan Enforcer' -ErrorAction SilentlyContinue
if ($staleLogonTask) {
    throw 'Stale unreliable logon task still exists.'
}

$conflictTask = Get-ScheduledTask -TaskName 'Hermes Ultimate Performance Refresh' -ErrorAction SilentlyContinue
if ($conflictTask -and $conflictTask.Settings.Enabled) {
    throw 'Conflicting Hermes Ultimate Performance Refresh task is still enabled.'
}

$settingChecks = @(
    @{ Label = 'CPU min'; Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN'; Expected = '0x00000064' },
    @{ Label = 'CPU max'; Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMAX'; Expected = '0x00000064' },
    @{ Label = 'PCIe ASPM'; Sub = 'SUB_PCIEXPRESS'; Setting = 'ASPM'; Expected = '0x00000000' },
    @{ Label = 'USB selective suspend'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Expected = '0x00000000' },
    @{ Label = 'Hard disk idle'; Sub = 'SUB_DISK'; Setting = 'DISKIDLE'; Expected = '0x00000000' }
)

foreach ($check in $settingChecks) {
    $query = powercfg /qh $persistedGuid $check.Sub $check.Setting | Out-String
    if ($query -notmatch "Current AC Power Setting Index:\s*$([regex]::Escape($check.Expected))") {
        throw "AC readback mismatch for $($check.Label)"
    }
    if ($query -notmatch "Current DC Power Setting Index:\s*$([regex]::Escape($check.Expected))") {
        throw "DC readback mismatch for $($check.Label)"
    }
}

$nvidia = nvidia-smi --query-gpu=power.limit,power.max_limit,clocks.max.graphics,clocks.max.memory,clocks.current.memory --format=csv,noheader,nounits 2>&1
if ($LASTEXITCODE -eq 0 -and $nvidia) {
    $parts = @($nvidia[0] -split '\s*,\s*')
    if ($parts.Count -ge 5) {
        if ([decimal] $parts[0] -lt [decimal] $parts[1]) {
            throw "NVIDIA power limit is below maximum: $($parts[0]) < $($parts[1])"
        }
        if ([int] $parts[4] -lt [int] $parts[3]) {
            throw "NVIDIA memory clock is below maximum lock: $($parts[4]) < $($parts[3])"
        }
    }
}

$boostSlider = nvidia-smi boost-slider -l 2>&1
if ($LASTEXITCODE -eq 0 -and ($boostSlider | Out-String) -match '\|\s*\d+\s+vboost\s+(\d+)\s+(\d+)\s*\|') {
    if ([int] $matches[2] -lt [int] $matches[1]) {
        throw "NVIDIA vboost slider is below maximum: $($matches[2]) < $($matches[1])"
    }
}

Import-Module NetAdapter -ErrorAction SilentlyContinue
if (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue) {
    foreach ($keyword in '*PMARPOffload', '*PMNSOffload') {
        $prop = Get-NetAdapterAdvancedProperty -Name 'Ethernet' -RegistryKeyword $keyword -ErrorAction SilentlyContinue
        if ($prop) {
            $actual = @($prop.RegistryValue | Select-Object -First 1)
            if ($actual.Count -gt 0 -and ([string] $actual[0]) -ne '0') {
                throw "Ethernet low-power offload is not disabled: $keyword=$($actual[0])"
            }
        }
    }
}

'PASS'
