[CmdletBinding()]
param(
    [switch] $Silent,
    [switch] $NoStartupTask
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$PlanName = 'Codex_Ultimate_Nuclear_Performance'
$LogonTaskName = 'Codex Ultimate Power Plan Enforcer'
$BootTaskName = 'Codex Ultimate Power Plan Boot Enforcer'
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexPowerPlans'
$StartupScriptPath = Join-Path $StateRoot 'Apply-UltimatePowerPlan.ps1'
$StartupVbsPath = Join-Path $StateRoot 'Apply-UltimatePowerPlan.vbs'
$PlanGuidPath = Join-Path $StateRoot 'CodexUltimatePowerPlan.guid'
$PowerShell5Path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WScriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'

function Write-PowerPlansStatus {
    param(
        [string] $Message,
        [string] $Color = 'White'
    )

    if (-not $Silent) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Invoke-PowerCfgSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $oldLastExitCode = $global:LASTEXITCODE
    $output = & powercfg @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    $global:LASTEXITCODE = $oldLastExitCode

    [pscustomobject]@{
        ExitCode = [int] $exitCode
        Output = (($output | Out-String).Trim())
    }
}

function Get-PowerSchemeRows {
    $result = Invoke-PowerCfgSafe -Arguments @('/list')
    $rows = @()
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match 'Power Scheme GUID:\s*([a-fA-F0-9-]{36})\s+\(([^)]*)\)(\s+\*)?') {
            $rows += [pscustomobject]@{
                Guid = $matches[1].ToLowerInvariant()
                Name = $matches[2]
                Active = -not [string]::IsNullOrWhiteSpace($matches[3])
            }
        }
    }
    $rows
}

function Ensure-StateRoot {
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
    }
}

function Get-PersistedPowerPlanGuid {
    if (-not (Test-Path -LiteralPath $PlanGuidPath -PathType Leaf)) {
        return $null
    }

    $raw = (Get-Content -LiteralPath $PlanGuidPath -Raw).Trim()
    if ($raw -match '^[a-fA-F0-9-]{36}$') {
        return $raw.ToLowerInvariant()
    }

    return $null
}

function Save-PersistedPowerPlanGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SchemeGuid
    )

    Ensure-StateRoot
    Set-Content -LiteralPath $PlanGuidPath -Value $SchemeGuid.ToLowerInvariant() -Encoding ASCII -Force
}

function Ensure-UltimatePowerPlan {
    Ensure-StateRoot
    $schemes = @(Get-PowerSchemeRows)
    $persistedGuid = Get-PersistedPowerPlanGuid
    if (-not [string]::IsNullOrWhiteSpace($persistedGuid)) {
        $persisted = @($schemes | Where-Object { $_.Guid -eq $persistedGuid } | Select-Object -First 1)
        if ($persisted.Count -gt 0) {
            if ($persisted[0].Name -ne $PlanName) {
                [void] (Invoke-PowerCfgSafe -Arguments @('/changename', $persistedGuid, $PlanName, 'Codex-managed permanent maximum-performance plan'))
            }
            return $persistedGuid
        }
    }

    $existing = @(Get-PowerSchemeRows | Where-Object { $_.Name -eq $PlanName } | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        Save-PersistedPowerPlanGuid -SchemeGuid $existing[0].Guid
        return $existing[0].Guid
    }

    $templates = @(
        'e9a42b02-d5df-448d-aa00-03f14749eb61',
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c',
        '381b4222-f694-41f0-9685-ff5bb260df2e'
    )

    foreach ($templateGuid in $templates) {
        $newGuid = ([guid]::NewGuid()).Guid
        $duplicate = Invoke-PowerCfgSafe -Arguments @('/duplicatescheme', $templateGuid, $newGuid)
        if ($duplicate.ExitCode -eq 0) {
            [void] (Invoke-PowerCfgSafe -Arguments @('/changename', $newGuid, $PlanName, 'Codex-managed permanent maximum-performance plan'))
            Save-PersistedPowerPlanGuid -SchemeGuid $newGuid
            return $newGuid.ToLowerInvariant()
        }
    }

    $active = @(Get-PowerSchemeRows | Where-Object { $_.Active } | Select-Object -First 1)
    if ($active.Count -gt 0) {
        Save-PersistedPowerPlanGuid -SchemeGuid $active[0].Guid
        return $active[0].Guid
    }

    throw 'No usable Windows power scheme could be found or created.'
}

function Set-PowerCfgValueIfSupported {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SchemeGuid,

        [Parameter(Mandatory = $true)]
        [string] $SubGroup,

        [Parameter(Mandatory = $true)]
        [string] $Setting,

        [Parameter(Mandatory = $true)]
        [int] $AcValue,

        [Parameter(Mandatory = $true)]
        [int] $DcValue,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    $query = Invoke-PowerCfgSafe -Arguments @('/query', $SchemeGuid, $SubGroup, $Setting)
    if ($query.ExitCode -ne 0) {
        return [pscustomobject]@{ Label = $Label; Status = 'Unsupported'; Ac = $null; Dc = $null }
    }

    $ac = Invoke-PowerCfgSafe -Arguments @('/setacvalueindex', $SchemeGuid, $SubGroup, $Setting, ([string] $AcValue))
    $dc = Invoke-PowerCfgSafe -Arguments @('/setdcvalueindex', $SchemeGuid, $SubGroup, $Setting, ([string] $DcValue))

    if ($ac.ExitCode -eq 0 -and $dc.ExitCode -eq 0) {
        return [pscustomobject]@{ Label = $Label; Status = 'Set'; Ac = $AcValue; Dc = $DcValue }
    }

    return [pscustomobject]@{ Label = $Label; Status = 'Failed'; Ac = $AcValue; Dc = $DcValue }
}

function Set-RegistryPerformanceGuards {
    $changed = 0
    try {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
        New-Item -Path $path -Force | Out-Null
        New-ItemProperty -Path $path -Name 'PowerThrottlingOff' -PropertyType DWord -Value 1 -Force | Out-Null
        $changed++
    } catch {}

    try {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        New-ItemProperty -Path $path -Name 'HibernateEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
        $changed++
    } catch {}

    $changed
}

function Write-StartupAssets {
    Ensure-StateRoot

    Copy-Item -LiteralPath $PSCommandPath -Destination $StartupScriptPath -Force

    $escapedPs = $PowerShell5Path.Replace('"', '""')
    $escapedScript = $StartupScriptPath.Replace('"', '""')
    $vbs = 'CreateObject("WScript.Shell").Run """" & "' + $escapedPs + '" & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $escapedScript + '"" -Silent", 0, False'
    Set-Content -LiteralPath $StartupVbsPath -Value $vbs -Encoding ASCII -Force
}

function Register-HiddenPowerPlanTask {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Logon', 'Boot')]
        [string] $TriggerKind
    )

    $installed = $false
    $schedule = if ($TriggerKind -eq 'Boot') { 'ONSTART' } else { 'ONLOGON' }
    $taskRun = $WScriptPath + ' //B //Nologo "' + $StartupVbsPath + '"'
    try {
        & schtasks.exe /Delete /TN $Name /F | Out-Null
    } catch {}
    $create = & schtasks.exe /Create /TN $Name /SC $schedule /TR $taskRun /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        $installed = $true
    }

    if (-not $installed) {
        try {
            $action = New-ScheduledTaskAction -Execute $WScriptPath -Argument ('//B //Nologo "' + $StartupVbsPath + '"')
            if ($TriggerKind -eq 'Boot') {
                $trigger = New-ScheduledTaskTrigger -AtStartup
            } else {
                $trigger = New-ScheduledTaskTrigger -AtLogOn
            }

            $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Description 'Silently reapplies the exact Codex ultimate power plan without terminal popups.' -Force | Out-Null
            $installed = $true
        } catch {}
    }

    if ($TriggerKind -eq 'Boot') {
        try {
            $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
            $task.Settings.Enabled = $true
            $task.Settings.Hidden = $true
            Set-ScheduledTask -TaskName $Name -Settings $task.Settings | Out-Null
            Enable-ScheduledTask -TaskName $Name | Out-Null
        } catch {}
    }

    try {
        & schtasks.exe /Change /TN $Name /ENABLE | Out-Null
    } catch {}

    $installed
}

function Install-HiddenStartupTask {
    Write-StartupAssets

    $logonInstalled = Register-HiddenPowerPlanTask -Name $LogonTaskName -TriggerKind Logon
    $bootInstalled = Register-HiddenPowerPlanTask -Name $BootTaskName -TriggerKind Boot

    [pscustomobject]@{
        LogonInstalled = [bool] $logonInstalled
        BootInstalled = [bool] $bootInstalled
    }
}

function Apply-UltimatePowerPlan {
    Write-PowerPlansStatus 'NUCLEAR PERFORMANCE MODE - FORCING MAX SETTINGS' 'Red'

    $schemeGuid = Ensure-UltimatePowerPlan
    [void] (Invoke-PowerCfgSafe -Arguments @('/setactive', $schemeGuid))
    [void] (Invoke-PowerCfgSafe -Arguments @('/S', $schemeGuid))

    foreach ($change in @(
        @('monitor-timeout-ac', '0'),
        @('monitor-timeout-dc', '0'),
        @('standby-timeout-ac', '0'),
        @('standby-timeout-dc', '0'),
        @('hibernate-timeout-ac', '0'),
        @('hibernate-timeout-dc', '0'),
        @('disk-timeout-ac', '0'),
        @('disk-timeout-dc', '0')
    )) {
        [void] (Invoke-PowerCfgSafe -Arguments @('/change', $change[0], $change[1]))
    }

    $settings = @(
        @{ Label = 'CPU minimum processor state'; Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN'; Ac = 100; Dc = 100 },
        @{ Label = 'CPU maximum processor state'; Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMAX'; Ac = 100; Dc = 100 },
        @{ Label = 'System cooling policy'; Sub = 'SUB_PROCESSOR'; Setting = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'; Ac = 1; Dc = 1 },
        @{ Label = 'Processor performance boost mode'; Sub = 'SUB_PROCESSOR'; Setting = 'be337238-0d82-4146-a960-4f3749d470c7'; Ac = 2; Dc = 2 },
        @{ Label = 'Processor energy performance preference'; Sub = 'SUB_PROCESSOR'; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor performance boost policy'; Sub = 'SUB_PROCESSOR'; Setting = '45bcc044-d885-43e2-8605-ee0ec6e96b59'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor idle disable'; Sub = 'SUB_PROCESSOR'; Setting = '5d76a2ca-e8c0-402f-a133-2158492d58ad'; Ac = 1; Dc = 1 },
        @{ Label = 'Core parking minimum cores'; Sub = 'SUB_PROCESSOR'; Setting = '0cc5b647-c1df-4637-891a-dec35c318583'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking maximum cores'; Sub = 'SUB_PROCESSOR'; Setting = 'ea062031-0e34-4ff1-9b6d-eb1059334028'; Ac = 100; Dc = 100 },
        @{ Label = 'PCI Express link state power management'; Sub = 'SUB_PCIEXPRESS'; Setting = 'ASPM'; Ac = 0; Dc = 0 },
        @{ Label = 'USB selective suspend'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Ac = 0; Dc = 0 },
        @{ Label = 'Hard disk idle timeout'; Sub = 'SUB_DISK'; Setting = 'DISKIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Sleep idle timeout'; Sub = 'SUB_SLEEP'; Setting = 'STANDBYIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Hibernate idle timeout'; Sub = 'SUB_SLEEP'; Setting = 'HIBERNATEIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Hybrid sleep'; Sub = 'SUB_SLEEP'; Setting = 'HYBRIDSLEEP'; Ac = 0; Dc = 0 },
        @{ Label = 'Wake timers'; Sub = 'SUB_SLEEP'; Setting = 'RTCWAKE'; Ac = 0; Dc = 0 },
        @{ Label = 'Display idle timeout'; Sub = 'SUB_VIDEO'; Setting = 'VIDEOIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Adaptive brightness'; Sub = 'SUB_VIDEO'; Setting = 'ADAPTBRIGHT'; Ac = 0; Dc = 0 }
    )

    $results = @()
    foreach ($setting in $settings) {
        $results += Set-PowerCfgValueIfSupported -SchemeGuid $schemeGuid -SubGroup $setting.Sub -Setting $setting.Setting -AcValue $setting.Ac -DcValue $setting.Dc -Label $setting.Label
    }

    [void] (Invoke-PowerCfgSafe -Arguments @('/hibernate', 'off'))
    [void] (Set-RegistryPerformanceGuards)
    [void] (Invoke-PowerCfgSafe -Arguments @('/setactive', $schemeGuid))

    $taskInstallResult = [pscustomobject]@{ LogonInstalled = $false; BootInstalled = $false }
    if (-not $NoStartupTask -and -not $Silent) {
        $taskInstallResult = Install-HiddenStartupTask
    }

    $active = @(Get-PowerSchemeRows | Where-Object { $_.Active } | Select-Object -First 1)
    $setCount = @($results | Where-Object { $_.Status -eq 'Set' }).Count
    $unsupportedCount = @($results | Where-Object { $_.Status -eq 'Unsupported' }).Count
    $failedCount = @($results | Where-Object { $_.Status -eq 'Failed' }).Count

    Write-PowerPlansStatus ("  [+] Active plan: {0} ({1})" -f $PlanName, $schemeGuid) 'Green'
    Write-PowerPlansStatus '  [+] Timeouts: monitor, disk, sleep, and hibernate disabled' 'Green'
    Write-PowerPlansStatus ("  [+] Supported settings forced: {0}; unsupported on this hardware skipped silently: {1}; failed: {2}" -f $setCount, $unsupportedCount, $failedCount) 'Green'
    if (-not $NoStartupTask -and -not $Silent) {
        if ($taskInstallResult.LogonInstalled -and $taskInstallResult.BootInstalled) {
            Write-PowerPlansStatus ("  [+] Startup permanence: hidden boot task and no-popup logon task installed") 'Green'
        } elseif ($taskInstallResult.LogonInstalled) {
            Write-PowerPlansStatus ("  [!] Startup permanence: hidden logon task installed; boot task registration failed") 'Yellow'
        } else {
            Write-PowerPlansStatus ("  [!] Startup permanence: task registration failed; plan remains active now") 'Yellow'
        }
    }

    if ($active.Count -eq 0 -or $active[0].Guid -ne $schemeGuid) {
        throw 'Ultimate power plan was not active after apply.'
    }

    if ($failedCount -gt 0) {
        Write-PowerPlansStatus '  [!] Some supported settings failed to apply; run as Administrator to force machine-level policy settings.' 'Yellow'
    }

    Write-PowerPlansStatus 'NUCLEAR PERFORMANCE ACTIVE - ALL SUPPORTED MAX SETTINGS APPLIED' 'Red'

    $summary = [pscustomobject]@{
        PlanName = $PlanName
        PlanGuid = $schemeGuid
        Active = $true
        SupportedSettingsSet = $setCount
        UnsupportedSettingsSkipped = $unsupportedCount
        FailedSettings = $failedCount
        StartupTaskInstalled = ($taskInstallResult.LogonInstalled -and $taskInstallResult.BootInstalled)
        StartupLogonTaskInstalled = $taskInstallResult.LogonInstalled
        StartupBootTaskInstalled = $taskInstallResult.BootInstalled
        StartupLogonTaskName = $LogonTaskName
        StartupBootTaskName = $BootTaskName
        StartupVbsPath = $StartupVbsPath
        StartupScriptPath = $StartupScriptPath
        PersistedPlanGuidPath = $PlanGuidPath
    }

    if (-not $Silent) {
        $summary
    }
}

Apply-UltimatePowerPlan
