[CmdletBinding()]
param(
    [switch] $Silent,
    [switch] $NoStartupTask
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$PlanName = 'Codex_Ultimate_Nuclear_Performance'
$BootTaskName = 'Codex Ultimate Power Plan Boot Enforcer'
$GuardTaskName = 'Codex Ultimate Power Plan Guard'
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexPowerPlans'
$StartupScriptPath = Join-Path $StateRoot 'Apply-UltimatePowerPlan.ps1'
$StartupVbsPath = Join-Path $StateRoot 'Apply-UltimatePowerPlan.vbs'
$PlanGuidPath = Join-Path $StateRoot 'CodexUltimatePowerPlan.guid'
$PowerShell5Path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WScriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$NvidiaSmiPath = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'

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

    $query = Invoke-PowerCfgSafe -Arguments @('/qh', $SchemeGuid, $SubGroup, $Setting)
    if ($query.ExitCode -ne 0) {
        return [pscustomobject]@{ Label = $Label; Status = 'Unsupported'; Ac = $null; Dc = $null }
    }

    $ac = Invoke-PowerCfgSafe -Arguments @('/setacvalueindex', $SchemeGuid, $SubGroup, $Setting, ([string] $AcValue))
    $dc = Invoke-PowerCfgSafe -Arguments @('/setdcvalueindex', $SchemeGuid, $SubGroup, $Setting, ([string] $DcValue))

    if ($ac.ExitCode -eq 0 -and $dc.ExitCode -eq 0) {
        return [pscustomobject]@{ Label = $Label; Status = 'Set'; Ac = $AcValue; Dc = $DcValue }
    }

    return [pscustomobject]@{ Label = $Label; Status = 'Failed'; Ac = $AcValue; Dc = $DcValue; AcExitCode = $ac.ExitCode; DcExitCode = $dc.ExitCode; AcOutput = $ac.Output; DcOutput = $dc.Output }
}

function Convert-ToPowerCfgIndex {
    param(
        [Parameter(Mandatory = $true)]
        [int] $Value
    )

    if ($Value -lt 0) {
        return [uint32]::MaxValue
    }

    return [uint32] $Value
}

function Test-PowerCfgValue {
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

    $query = Invoke-PowerCfgSafe -Arguments @('/qh', $SchemeGuid, $SubGroup, $Setting)
    if ($query.ExitCode -ne 0) {
        return [pscustomobject]@{ Label = $Label; Status = 'Unsupported'; ExpectedAc = $AcValue; ExpectedDc = $DcValue; ActualAc = $null; ActualDc = $null }
    }

    $actualAc = $null
    $actualDc = $null
    if ($query.Output -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
        $actualAc = [uint32]::Parse($matches[1], [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($query.Output -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
        $actualDc = [uint32]::Parse($matches[1], [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture)
    }

    $expectedAc = Convert-ToPowerCfgIndex -Value $AcValue
    $expectedDc = Convert-ToPowerCfgIndex -Value $DcValue
    if ($actualAc -eq $expectedAc -and $actualDc -eq $expectedDc) {
        return [pscustomobject]@{ Label = $Label; Status = 'Verified'; ExpectedAc = $expectedAc; ExpectedDc = $expectedDc; ActualAc = $actualAc; ActualDc = $actualDc }
    }

    [pscustomobject]@{ Label = $Label; Status = 'Mismatch'; ExpectedAc = $expectedAc; ExpectedDc = $expectedDc; ActualAc = $actualAc; ActualDc = $actualDc }
}

function Get-KnownUnsupportedPowerCfgEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SchemeGuid
    )

    $unsupported = @(
        @{
            Label = 'Energy Saver Policy write target'
            Sub = 'de830923-a562-41af-a086-e3a2c6bad2da'
            Setting = '5c5bb349-ad29-4ee2-9d0b-2b25270f7a81'
            Ac = 0
            Dc = 0
        }
    )

    $evidence = @()
    foreach ($item in $unsupported) {
        $ac = Invoke-PowerCfgSafe -Arguments @('/setacvalueindex', $SchemeGuid, $item.Sub, $item.Setting, ([string] $item.Ac))
        $dc = Invoke-PowerCfgSafe -Arguments @('/setdcvalueindex', $SchemeGuid, $item.Sub, $item.Setting, ([string] $item.Dc))
        if ($ac.ExitCode -ne 0 -or $dc.ExitCode -ne 0) {
            $evidence += [pscustomobject]@{
                Label = $item.Label
                Status = 'WriteRejectedByPowerCfg'
                AcExitCode = $ac.ExitCode
                DcExitCode = $dc.ExitCode
                Detail = (($ac.Output + ' ' + $dc.Output).Trim())
            }
        }
    }

    $evidence
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

function Set-NetworkAdapterMaximumPerformance {
    $changed = 0
    $verified = 0
    $unsupported = 0
    $details = @()

    try {
        Import-Module NetAdapter -ErrorAction SilentlyContinue | Out-Null
        if (-not (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ Changed = 0; Verified = 0; Unsupported = 1; Detail = 'NetAdapter module unavailable' }
        }

        $targets = @(
            @{ Keyword = '*EEE'; Value = 0 },
            @{ Keyword = 'AdvancedEEE'; Value = 0 },
            @{ Keyword = 'EnableGreenEthernet'; Value = 0 },
            @{ Keyword = 'PowerSavingMode'; Value = 0 },
            @{ Keyword = '*PMARPOffload'; Value = 0 },
            @{ Keyword = '*PMNSOffload'; Value = 0 }
        )

        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -in @('Up', 'Disconnected') })
        foreach ($adapter in $adapters) {
            foreach ($target in $targets) {
                $prop = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $target.Keyword -ErrorAction SilentlyContinue
                if (-not $prop) {
                    continue
                }

                Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $target.Keyword -RegistryValue $target.Value -NoRestart -ErrorAction SilentlyContinue
                $changed++
                $after = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $target.Keyword -ErrorAction SilentlyContinue
                $actual = @($after.RegistryValue | Select-Object -First 1)
                if ($actual.Count -gt 0 -and ([string] $actual[0]) -eq ([string] $target.Value)) {
                    $verified++
                } else {
                    $details += ('{0}:{1}' -f $adapter.Name, $target.Keyword)
                }
            }
        }
    } catch {
        $unsupported++
        $details += $_.Exception.Message
    }

    [pscustomobject]@{
        Changed = $changed
        Verified = $verified
        Unsupported = $unsupported
        Detail = (($details | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; ')
    }
}

function Invoke-NvidiaSmiSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = 127; Output = 'nvidia-smi.exe not found' }
    }

    $oldLastExitCode = $global:LASTEXITCODE
    $output = & $NvidiaSmiPath @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    $global:LASTEXITCODE = $oldLastExitCode

    [pscustomobject]@{
        ExitCode = [int] $exitCode
        Output = (($output | Out-String).Trim())
    }
}

function Set-NvidiaMaximumPerformance {
    $query = Invoke-NvidiaSmiSafe -Arguments @(
        '--query-gpu=index,name,power.max_limit,clocks.max.graphics,clocks.max.memory',
        '--format=csv,noheader,nounits'
    )
    if ($query.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($query.Output)) {
        return [pscustomobject]@{
            Status = 'Unsupported'
            Detail = $query.Output
            PowerLimitSet = $false
            GraphicsClockLocked = $false
            MemoryClockLocked = $false
            BoostSliderSet = $false
        }
    }

    $powerSet = $false
    $graphicsLocked = $false
    $memoryLocked = $false
    $boostSliderSet = $false
    $details = @()

    foreach ($line in ($query.Output -split "`r?`n")) {
        $parts = @($line -split '\s*,\s*')
        if ($parts.Count -lt 5) { continue }

        $gpuIndex = $parts[0]
        $maxPower = [decimal]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
        $maxGraphics = [int]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture)
        $maxMemory = [int]::Parse($parts[4], [Globalization.CultureInfo]::InvariantCulture)

        $pl = Invoke-NvidiaSmiSafe -Arguments @('-i', $gpuIndex, '-pl', ([string] $maxPower))
        if ($pl.ExitCode -eq 0) { $powerSet = $true } else { $details += $pl.Output }

        $lgc = Invoke-NvidiaSmiSafe -Arguments @('-i', $gpuIndex, '-lgc', ("{0},{0}" -f $maxGraphics))
        if ($lgc.ExitCode -eq 0) { $graphicsLocked = $true } else { $details += $lgc.Output }

        $lmc = Invoke-NvidiaSmiSafe -Arguments @('-i', $gpuIndex, '-lmc', ("{0},{0}" -f $maxMemory))
        if ($lmc.ExitCode -eq 0) { $memoryLocked = $true } else { $details += $lmc.Output }
    }

    $boostList = Invoke-NvidiaSmiSafe -Arguments @('boost-slider', '-l')
    if ($boostList.ExitCode -eq 0 -and $boostList.Output -match '\|\s*(\d+)\s+vboost\s+(\d+)\s+(\d+)\s*\|') {
        $boostGpuIndex = $matches[1]
        $boostMax = [int]::Parse($matches[2], [Globalization.CultureInfo]::InvariantCulture)
        $boostSet = Invoke-NvidiaSmiSafe -Arguments @('boost-slider', '-i', $boostGpuIndex, ('--vboost={0}' -f $boostMax))
        if ($boostSet.ExitCode -eq 0) {
            $boostVerify = Invoke-NvidiaSmiSafe -Arguments @('boost-slider', '-l')
            if ($boostVerify.ExitCode -eq 0 -and $boostVerify.Output -match '\|\s*\d+\s+vboost\s+\d+\s+(\d+)\s*\|' -and ([int] $matches[1]) -eq $boostMax) {
                $boostSliderSet = $true
            } else {
                $details += $boostVerify.Output
            }
        } else {
            $details += $boostSet.Output
        }
    } elseif ($boostList.ExitCode -ne 0) {
        $details += $boostList.Output
    }

    [pscustomobject]@{
        Status = if ($powerSet -or $graphicsLocked -or $memoryLocked -or $boostSliderSet) { 'Set' } else { 'Unsupported' }
        Detail = (($details | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; ')
        PowerLimitSet = $powerSet
        GraphicsClockLocked = $graphicsLocked
        MemoryClockLocked = $memoryLocked
        BoostSliderSet = $boostSliderSet
    }
}

function Set-AmdVendorPerformanceIfAvailable {
    $serviceResult = 'NotInstalled'
    $ryzenMasterCli = 'NotInstalled'
    $driverCli = 'NotInstalled'
    try {
        $service = Get-Service -Name 'amd3dvcacheSvc' -ErrorAction SilentlyContinue
        if ($service) {
            Set-Service -Name 'amd3dvcacheSvc' -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name 'amd3dvcacheSvc' -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            $service = Get-Service -Name 'amd3dvcacheSvc' -ErrorAction SilentlyContinue
            $serviceResult = if ($service) { $service.Status.ToString() } else { 'Unavailable' }
        }
    } catch {
        $serviceResult = 'Unsupported'
    }

    $ryzenMasterCmd = Join-Path ${env:ProgramFiles(x86)} 'GIGABYTE\EasyTuneEngineService\AMDRyzenMasterCmd.exe'
    if (Test-Path -LiteralPath $ryzenMasterCmd -PathType Leaf) {
        $output = (& $ryzenMasterCmd '/?' 2>&1 | Out-String).Trim()
        $ryzenMasterCli = if ($output -match 'unsupported|status:\s*failed') { 'Unsupported' } elseif ($output) { $output } else { 'Available' }
    }

    $driverCmd = Join-Path ${env:ProgramFiles(x86)} 'GIGABYTE\EasyTuneEngineService\AMD\Ryzen\AMDRyzenMasterDriverCmd.exe'
    if (Test-Path -LiteralPath $driverCmd -PathType Leaf) {
        $output = (& $driverCmd '/?' 2>&1 | Out-String).Trim()
        $driverCli = if ($output -match 'unsupported|status:\s*failed') { 'Unsupported' } elseif ($output) { $output } else { 'Available' }
    }

    [pscustomobject]@{
        VCacheService = $serviceResult
        RyzenMasterCli = $ryzenMasterCli
        RyzenMasterDriverCli = $driverCli
    }
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
        [ValidateSet('Logon', 'Boot', 'Guard')]
        [string] $TriggerKind
    )

    $installed = $false
    $schedule = if ($TriggerKind -eq 'Boot') {
        'ONSTART'
    } elseif ($TriggerKind -eq 'Guard') {
        'MINUTE'
    } else {
        'ONLOGON'
    }
    $taskRun = $WScriptPath + ' //B //Nologo "' + $StartupVbsPath + '"'
    try {
        & schtasks.exe /Delete /TN $Name /F 2>$null | Out-Null
    } catch {}
    if ($TriggerKind -eq 'Guard') {
        $create = & schtasks.exe /Create /TN $Name /SC $schedule /MO 1 /TR $taskRun /RU SYSTEM /RL HIGHEST /F 2>&1
    } else {
        $create = & schtasks.exe /Create /TN $Name /SC $schedule /TR $taskRun /RU SYSTEM /RL HIGHEST /F 2>&1
    }
    if ($LASTEXITCODE -eq 0) {
        $installed = $true
    }

    if (-not $installed) {
        try {
            $action = New-ScheduledTaskAction -Execute $WScriptPath -Argument ('//B //Nologo "' + $StartupVbsPath + '"')
            if ($TriggerKind -eq 'Boot') {
                $trigger = New-ScheduledTaskTrigger -AtStartup
            } elseif ($TriggerKind -eq 'Guard') {
                $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
            } else {
                $trigger = New-ScheduledTaskTrigger -AtLogOn
            }

            $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Silently reapplies the exact Codex ultimate power plan without terminal popups.' -Force | Out-Null
            $installed = $true
        } catch {}
    }

    if ($TriggerKind -ne 'Logon') {
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

function Disable-ConflictingPowerPlanTasks {
    $disabled = @()
    $knownConflicts = @(
        @{
            Name = 'Hermes Ultimate Performance Refresh'
            Reason = 'sets Windows Ultimate Performance active, which can replace the exact persisted Codex plan GUID'
        }
    )

    foreach ($conflict in $knownConflicts) {
        try {
            $task = Get-ScheduledTask -TaskName $conflict.Name -ErrorAction SilentlyContinue
            if ($task -and $task.Settings.Enabled) {
                Disable-ScheduledTask -TaskName $conflict.Name -ErrorAction SilentlyContinue | Out-Null
                $after = Get-ScheduledTask -TaskName $conflict.Name -ErrorAction SilentlyContinue
                if ($after -and -not $after.Settings.Enabled) {
                    $disabled += [pscustomobject]@{ Name = $conflict.Name; Reason = $conflict.Reason }
                }
            }
        } catch {}
    }

    $disabled
}

function Install-HiddenStartupTask {
    Write-StartupAssets

    try {
        & schtasks.exe /Delete /TN 'Codex Ultimate Power Plan Enforcer' /F 2>$null | Out-Null
    } catch {}

    $bootInstalled = Register-HiddenPowerPlanTask -Name $BootTaskName -TriggerKind Boot
    $guardInstalled = Register-HiddenPowerPlanTask -Name $GuardTaskName -TriggerKind Guard

    [pscustomobject]@{
        BootInstalled = [bool] $bootInstalled
        GuardInstalled = [bool] $guardInstalled
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
        @{ Label = 'Power plan type'; Sub = 'SUB_NONE'; Setting = '245d8541-3943-4422-b025-13a784f679b7'; Ac = 1; Dc = 1 },
        @{ Label = 'Device idle policy'; Sub = 'SUB_NONE'; Setting = '4faab71a-92e5-4726-b531-224559672d19'; Ac = 0; Dc = 0 },
        @{ Label = 'Energy Saver Policy'; Sub = 'de830923-a562-41af-a086-e3a2c6bad2da'; Setting = '5c5bb349-ad29-4ee2-9d0b-2b25270f7a81'; Ac = 0; Dc = 0 },
        @{ Label = 'Energy Saver display brightness weight'; Sub = 'de830923-a562-41af-a086-e3a2c6bad2da'; Setting = '13d09884-f74e-474a-a852-b6bde8ad03a8'; Ac = 100; Dc = 100 },
        @{ Label = 'AHCI link power management HIPM/DIPM'; Sub = 'SUB_DISK'; Setting = '0b2d69d7-a2a1-449c-9680-f91c70521c60'; Ac = 0; Dc = 0 },
        @{ Label = 'Disk maximum power level'; Sub = 'SUB_DISK'; Setting = '51dea550-bb38-4bc4-991b-eacf37be5ec8'; Ac = 100; Dc = 100 },
        @{ Label = 'Hard disk burst ignore time'; Sub = 'SUB_DISK'; Setting = '80e3c60e-bb94-4ad8-bbe0-0d3195efc663'; Ac = 0; Dc = 0 },
        @{ Label = 'Primary NVMe idle timeout'; Sub = 'SUB_DISK'; Setting = 'd639518a-e56d-4345-8af2-b9f32fb26109'; Ac = 0; Dc = 0 },
        @{ Label = 'Secondary NVMe idle timeout'; Sub = 'SUB_DISK'; Setting = 'd3d55efd-c1ff-424e-9dc3-441be7833010'; Ac = 0; Dc = 0 },
        @{ Label = 'AHCI link power management adaptive'; Sub = 'SUB_DISK'; Setting = 'dab60367-53fe-4fbc-825e-521d069d2456'; Ac = 0; Dc = 0 },
        @{ Label = 'Primary NVMe latency tolerance'; Sub = 'SUB_DISK'; Setting = 'fc95af4d-40e7-4b6d-835a-56d131dbc80e'; Ac = 0; Dc = 0 },
        @{ Label = 'Secondary NVMe latency tolerance'; Sub = 'SUB_DISK'; Setting = 'dbc9e238-6de9-49e3-92cd-8c2b4946b472'; Ac = 0; Dc = 0 },
        @{ Label = 'NVMe NOPPME'; Sub = 'SUB_DISK'; Setting = 'fc7372b6-ab2d-43ee-8797-15e9841f2cca'; Ac = 1; Dc = 1 },
        @{ Label = 'JavaScript timer maximum performance'; Sub = '02f815b5-a5cf-4c84-bf20-649d1f75d3d8'; Setting = '4c793e7d-a264-42e1-87d3-7a0d2f523ccd'; Ac = 1; Dc = 1 },
        @{ Label = 'Wireless adapter maximum performance'; Sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; Ac = 0; Dc = 0 },
        @{ Label = 'Video playback performance bias'; Sub = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; Setting = '10778347-1370-4ee0-8bbd-33bdacaade49'; Ac = 1; Dc = 1 },
        @{ Label = 'Media sharing prevents idle sleep'; Sub = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; Setting = '03680956-93bc-4294-bba6-4e0f09bb717f'; Ac = 1; Dc = 1 },
        @{ Label = 'System unattended sleep timeout'; Sub = 'SUB_SLEEP'; Setting = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'; Ac = 0; Dc = 0 },
        @{ Label = 'Allow standby states'; Sub = 'SUB_SLEEP'; Setting = 'abfc2519-3608-4c2a-94ea-171b0ed546ab'; Ac = 0; Dc = 0 },
        @{ Label = 'Allow sleep with remote opens'; Sub = 'SUB_SLEEP'; Setting = 'd4c1d4c8-d5cc-43d3-b83e-fc51215cb04d'; Ac = 0; Dc = 0 },
        @{ Label = 'USB hub selective suspend timeout'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '0853a681-27c8-4100-a2fd-82013e970683'; Ac = 0; Dc = 0 },
        @{ Label = 'USB 3 link power management'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'; Ac = 0; Dc = 0 },
        @{ Label = 'USB IOC on all TDs'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '498c044a-201b-4631-a522-5c744ed4e678'; Ac = 1; Dc = 1 },
        @{ Label = 'Execution required timeout'; Sub = 'SUB_IR'; Setting = '3166bc41-7e98-4e03-b34e-ec0f5f2b218e'; Ac = -1; Dc = -1 },
        @{ Label = 'IO coalescing timeout'; Sub = 'SUB_IR'; Setting = 'c36f0eb4-2988-4a70-8eee-0884fc2c2433'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor idle resiliency timer resolution'; Sub = 'SUB_IR'; Setting = 'c42b79aa-aa3a-484b-a98f-2cf32aa90a28'; Ac = 0; Dc = 0 },
        @{ Label = 'Deep sleep'; Sub = 'SUB_IR'; Setting = 'd502f7ee-1dc7-4efd-a55d-f04b6f5c0545'; Ac = 0; Dc = 0 },
        @{ Label = 'CPU minimum processor state'; Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMIN'; Ac = 100; Dc = 100 },
        @{ Label = 'CPU minimum processor state class 1'; Sub = 'SUB_PROCESSOR'; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964d'; Ac = 100; Dc = 100 },
        @{ Label = 'CPU minimum processor state class 2'; Sub = 'SUB_PROCESSOR'; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964e'; Ac = 100; Dc = 100 },
        @{ Label = 'CPU maximum processor state'; Sub = 'SUB_PROCESSOR'; Setting = 'PROCTHROTTLEMAX'; Ac = 100; Dc = 100 },
        @{ Label = 'CPU maximum processor state class 1'; Sub = 'SUB_PROCESSOR'; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ed'; Ac = 100; Dc = 100 },
        @{ Label = 'CPU maximum processor state class 2'; Sub = 'SUB_PROCESSOR'; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ee'; Ac = 100; Dc = 100 },
        @{ Label = 'System cooling policy'; Sub = 'SUB_PROCESSOR'; Setting = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'; Ac = 1; Dc = 1 },
        @{ Label = 'Processor performance boost mode'; Sub = 'SUB_PROCESSOR'; Setting = 'be337238-0d82-4146-a960-4f3749d470c7'; Ac = 2; Dc = 2 },
        @{ Label = 'Processor energy performance preference'; Sub = 'SUB_PROCESSOR'; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor energy performance preference class 1'; Sub = 'SUB_PROCESSOR'; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6864'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor energy performance preference class 2'; Sub = 'SUB_PROCESSOR'; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6865'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor performance boost policy'; Sub = 'SUB_PROCESSOR'; Setting = '45bcc044-d885-43e2-8605-ee0ec6e96b59'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor idle disable'; Sub = 'SUB_PROCESSOR'; Setting = '5d76a2ca-e8c0-402f-a133-2158492d58ad'; Ac = 1; Dc = 1 },
        @{ Label = 'Maximum processor frequency unlimited'; Sub = 'SUB_PROCESSOR'; Setting = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'; Ac = 0; Dc = 0 },
        @{ Label = 'Maximum processor frequency class 1 unlimited'; Sub = 'SUB_PROCESSOR'; Setting = '75b0ae3f-bce0-45a7-8c89-c9611c25e101'; Ac = 0; Dc = 0 },
        @{ Label = 'Maximum processor frequency class 2 unlimited'; Sub = 'SUB_PROCESSOR'; Setting = '75b0ae3f-bce0-45a7-8c89-c9611c25e102'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor performance increase policy rocket'; Sub = 'SUB_PROCESSOR'; Setting = '465e1f50-b610-473a-ab58-00d1077dc418'; Ac = 2; Dc = 2 },
        @{ Label = 'Processor performance decrease policy single'; Sub = 'SUB_PROCESSOR'; Setting = '40fbefc7-2e9d-4d25-a185-0cfd8574bac6'; Ac = 1; Dc = 1 },
        @{ Label = 'Processor performance increase threshold class 1'; Sub = 'SUB_PROCESSOR'; Setting = '06cadf0e-64ed-448a-8927-ce7bf90eb35e'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor performance decrease threshold class 1'; Sub = 'SUB_PROCESSOR'; Setting = '12a0ab44-fe28-4fa9-b3bd-4b64f44960a7'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor performance increase time class 1'; Sub = 'SUB_PROCESSOR'; Setting = '984cf492-3bed-4488-a8f9-4286c97bf5ab'; Ac = 1; Dc = 1 },
        @{ Label = 'Processor performance decrease time class 1'; Sub = 'SUB_PROCESSOR'; Setting = 'd8edeb9b-95cf-4f95-a73c-b061973693c9'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor duty cycling disabled'; Sub = 'SUB_PROCESSOR'; Setting = '4e4450b3-6179-4e91-b8f1-5bb9938f81a1'; Ac = 0; Dc = 0 },
        @{ Label = 'Latency hint processor EPP performance'; Sub = 'SUB_PROCESSOR'; Setting = '4b70f900-cdd9-4e66-aa26-ae8417f98173'; Ac = 0; Dc = 0 },
        @{ Label = 'Latency hint processor EPP class 1 performance'; Sub = 'SUB_PROCESSOR'; Setting = '4b70f900-cdd9-4e66-aa26-ae8417f98174'; Ac = 0; Dc = 0 },
        @{ Label = 'Latency hint processor EPP class 2 performance'; Sub = 'SUB_PROCESSOR'; Setting = '4b70f900-cdd9-4e66-aa26-ae8417f98175'; Ac = 0; Dc = 0 },
        @{ Label = 'Latency hint processor performance'; Sub = 'SUB_PROCESSOR'; Setting = '619b7505-003b-4e82-b7a6-4dd29c300971'; Ac = 100; Dc = 100 },
        @{ Label = 'Latency hint processor performance class 1'; Sub = 'SUB_PROCESSOR'; Setting = '619b7505-003b-4e82-b7a6-4dd29c300972'; Ac = 100; Dc = 100 },
        @{ Label = 'Latency hint processor performance class 2'; Sub = 'SUB_PROCESSOR'; Setting = '619b7505-003b-4e82-b7a6-4dd29c300973'; Ac = 100; Dc = 100 },
        @{ Label = 'Latency hint minimum unparked cores'; Sub = 'SUB_PROCESSOR'; Setting = '616cdaa5-695e-4545-97ad-97dc2d1bdd88'; Ac = 100; Dc = 100 },
        @{ Label = 'Latency hint minimum unparked cores class 1'; Sub = 'SUB_PROCESSOR'; Setting = '616cdaa5-695e-4545-97ad-97dc2d1bdd89'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor resource priority'; Sub = 'SUB_PROCESSOR'; Setting = '603fe9ce-8d01-4b48-a968-1d706c28fd5c'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor resource priority class 1'; Sub = 'SUB_PROCESSOR'; Setting = '603fe9ce-8d01-4b48-a968-1d706c28fd5d'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor resource priority class 2'; Sub = 'SUB_PROCESSOR'; Setting = '603fe9ce-8d01-4b48-a968-1d706c28fd5e'; Ac = 100; Dc = 100 },
        @{ Label = 'Allow throttle states'; Sub = 'SUB_PROCESSOR'; Setting = '3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor autonomous mode'; Sub = 'SUB_PROCESSOR'; Setting = '8baa4a8a-14c6-4451-8e8b-14bdbd197537'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor autonomous activity window'; Sub = 'SUB_PROCESSOR'; Setting = 'cfeda3d0-7697-4566-a922-a9086cd49dfa'; Ac = 0; Dc = 0 },
        @{ Label = 'Core parking minimum cores'; Sub = 'SUB_PROCESSOR'; Setting = '0cc5b647-c1df-4637-891a-dec35c318583'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking minimum cores class 1'; Sub = 'SUB_PROCESSOR'; Setting = '0cc5b647-c1df-4637-891a-dec35c318584'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking maximum cores'; Sub = 'SUB_PROCESSOR'; Setting = 'ea062031-0e34-4ff1-9b6d-eb1059334028'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking maximum cores class 1'; Sub = 'SUB_PROCESSOR'; Setting = 'ea062031-0e34-4ff1-9b6d-eb1059334029'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking soft park latency'; Sub = 'SUB_PROCESSOR'; Setting = '97cfac41-2217-47eb-992d-618b1977c907'; Ac = 0; Dc = 0 },
        @{ Label = 'Core parking over-utilisation threshold'; Sub = 'SUB_PROCESSOR'; Setting = '943c8cb6-6f93-4227-ad87-e9a3feec08d1'; Ac = 5; Dc = 5 },
        @{ Label = 'Core parking concurrency threshold'; Sub = 'SUB_PROCESSOR'; Setting = '2430ab6f-a520-44a2-9601-f7f23b5134b1'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking headroom threshold'; Sub = 'SUB_PROCESSOR'; Setting = 'f735a673-2066-4f80-a0c5-ddee0cf1bf5d'; Ac = 0; Dc = 0 },
        @{ Label = 'Core parking increase time'; Sub = 'SUB_PROCESSOR'; Setting = '2ddd5a84-5a71-437e-912a-db0b8c788732'; Ac = 1; Dc = 1 },
        @{ Label = 'Core parking decrease time'; Sub = 'SUB_PROCESSOR'; Setting = 'dfd10d17-d5eb-45dd-877a-9a34ddd15c82'; Ac = 100; Dc = 100 },
        @{ Label = 'Core parking distribution threshold'; Sub = 'SUB_PROCESSOR'; Setting = '4bdaf4e9-d103-46d7-a5f0-6280121616ef'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor performance increase threshold'; Sub = 'SUB_PROCESSOR'; Setting = '06cadf0e-64ed-448a-8927-ce7bf90eb35d'; Ac = 0; Dc = 0 },
        @{ Label = 'Processor performance decrease threshold'; Sub = 'SUB_PROCESSOR'; Setting = '12a0ab44-fe28-4fa9-b3bd-4b64f44960a6'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor performance increase time'; Sub = 'SUB_PROCESSOR'; Setting = '984cf492-3bed-4488-a8f9-4286c97bf5aa'; Ac = 1; Dc = 1 },
        @{ Label = 'Processor performance decrease time'; Sub = 'SUB_PROCESSOR'; Setting = 'd8edeb9b-95cf-4f95-a73c-b061973693c8'; Ac = 100; Dc = 100 },
        @{ Label = 'Processor idle state maximum'; Sub = 'SUB_PROCESSOR'; Setting = '9943e905-9a30-4ec1-9b99-44dd3b76f7a2'; Ac = 0; Dc = 0 },
        @{ Label = 'PCI Express link state power management'; Sub = 'SUB_PCIEXPRESS'; Setting = 'ASPM'; Ac = 0; Dc = 0 },
        @{ Label = 'USB selective suspend'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Ac = 0; Dc = 0 },
        @{ Label = 'Hard disk idle timeout'; Sub = 'SUB_DISK'; Setting = 'DISKIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Sleep idle timeout'; Sub = 'SUB_SLEEP'; Setting = 'STANDBYIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Hibernate idle timeout'; Sub = 'SUB_SLEEP'; Setting = 'HIBERNATEIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Hybrid sleep'; Sub = 'SUB_SLEEP'; Setting = 'HYBRIDSLEEP'; Ac = 0; Dc = 0 },
        @{ Label = 'Away mode policy'; Sub = 'SUB_SLEEP'; Setting = '25dfa149-5dd1-4736-b5ab-e8a37b5b8187'; Ac = 0; Dc = 0 },
        @{ Label = 'Wake timers'; Sub = 'SUB_SLEEP'; Setting = 'RTCWAKE'; Ac = 0; Dc = 0 },
        @{ Label = 'Display idle timeout'; Sub = 'SUB_VIDEO'; Setting = 'VIDEOIDLE'; Ac = 0; Dc = 0 },
        @{ Label = 'Dim display timeout'; Sub = 'SUB_VIDEO'; Setting = '17aaa29b-8b43-4b94-aafe-35f64daaf1ee'; Ac = 0; Dc = 0 },
        @{ Label = 'Console lock display timeout'; Sub = 'SUB_VIDEO'; Setting = '8ec4b3a5-6868-48c2-be75-4f3044be88a7'; Ac = 0; Dc = 0 },
        @{ Label = 'Advanced colour visual quality bias'; Sub = 'SUB_VIDEO'; Setting = '684c3e69-a4f7-4014-8754-d45179a56167'; Ac = 1; Dc = 1 },
        @{ Label = 'Allow display required policy'; Sub = 'SUB_VIDEO'; Setting = 'a9ceb8da-cd46-44fb-a98b-02af69de4623'; Ac = 1; Dc = 1 },
        @{ Label = 'Adaptive brightness'; Sub = 'SUB_VIDEO'; Setting = 'ADAPTBRIGHT'; Ac = 0; Dc = 0 },
        @{ Label = 'Adaptive display'; Sub = 'SUB_VIDEO'; Setting = '90959d22-d6a1-49b9-af93-bce885ad335b'; Ac = 0; Dc = 0 },
        @{ Label = 'Display brightness'; Sub = 'SUB_VIDEO'; Setting = 'VIDEONORMALLEVEL'; Ac = 100; Dc = 100 },
        @{ Label = 'Dimmed display brightness'; Sub = 'SUB_VIDEO'; Setting = 'f1fbfde2-a960-4165-9f88-50667911ce96'; Ac = 100; Dc = 100 },
        @{ Label = 'Presence away display timeout'; Sub = '8619b916-e004-4dd8-9b66-dae86f806698'; Setting = '0a7d6ab6-ac83-4ad1-8282-eca5b58308f3'; Ac = 0; Dc = 0 },
        @{ Label = 'Presence inattentive dim timeout'; Sub = '8619b916-e004-4dd8-9b66-dae86f806698'; Setting = 'cf8c6097-12b8-4279-bbdd-44601ee5209d'; Ac = 0; Dc = 0 },
        @{ Label = 'Non-sensor input presence timeout'; Sub = '8619b916-e004-4dd8-9b66-dae86f806698'; Setting = '5adbbfbc-074e-4da1-ba38-db8b36b2c8f3'; Ac = 0; Dc = 0 }
    )

    $results = @()
    foreach ($setting in $settings) {
        $results += Set-PowerCfgValueIfSupported -SchemeGuid $schemeGuid -SubGroup $setting.Sub -Setting $setting.Setting -AcValue $setting.Ac -DcValue $setting.Dc -Label $setting.Label
    }

    $verifiedResults = @()
    foreach ($setting in $settings) {
        $verifiedResults += Test-PowerCfgValue -SchemeGuid $schemeGuid -SubGroup $setting.Sub -Setting $setting.Setting -AcValue $setting.Ac -DcValue $setting.Dc -Label $setting.Label
    }

    $unsupportedEvidence = @(Get-KnownUnsupportedPowerCfgEvidence -SchemeGuid $schemeGuid)

    [void] (Invoke-PowerCfgSafe -Arguments @('/hibernate', 'off'))
    [void] (Set-RegistryPerformanceGuards)
    $networkResult = Set-NetworkAdapterMaximumPerformance
    $conflictsDisabled = @(Disable-ConflictingPowerPlanTasks)
    $nvidiaResult = Set-NvidiaMaximumPerformance
    $amdResult = Set-AmdVendorPerformanceIfAvailable
    [void] (Invoke-PowerCfgSafe -Arguments @('/setactive', $schemeGuid))

    $taskInstallResult = [pscustomobject]@{ BootInstalled = $false; GuardInstalled = $false }
    if (-not $NoStartupTask -and -not $Silent) {
        $taskInstallResult = Install-HiddenStartupTask
    }

    $active = @(Get-PowerSchemeRows | Where-Object { $_.Active } | Select-Object -First 1)
    $setCount = @($results | Where-Object { $_.Status -eq 'Set' }).Count
    $unsupportedCount = @($results | Where-Object { $_.Status -eq 'Unsupported' }).Count
    $failedCount = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    $failedLabels = @($results | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { $_.Label })
    $verifiedCount = @($verifiedResults | Where-Object { $_.Status -eq 'Verified' }).Count
    $mismatchCount = @($verifiedResults | Where-Object { $_.Status -eq 'Mismatch' }).Count
    $mismatchLabels = @($verifiedResults | Where-Object { $_.Status -eq 'Mismatch' } | ForEach-Object { $_.Label })

    Write-PowerPlansStatus ("  [+] Active plan: {0} ({1})" -f $PlanName, $schemeGuid) 'Green'
    Write-PowerPlansStatus '  [+] Timeouts: monitor, disk, sleep, and hibernate disabled' 'Green'
    Write-PowerPlansStatus ("  [+] Supported settings forced: {0}; unsupported on this hardware skipped silently: {1}; failed: {2}" -f $setCount, $unsupportedCount, $failedCount) 'Green'
    Write-PowerPlansStatus ("  [+] Readback verified settings: {0}; mismatches: {1}" -f $verifiedCount, $mismatchCount) 'Green'
    Write-PowerPlansStatus ("  [+] Conflicting plan switchers disabled this run: {0}" -f $conflictsDisabled.Count) 'Green'
    Write-PowerPlansStatus ("  [+] Unsupported/write-rejected setting probes proven: {0}" -f $unsupportedEvidence.Count) 'Green'
    Write-PowerPlansStatus ("  [+] NIC low-power features disabled/verified: {0}/{1}" -f $networkResult.Verified, $networkResult.Changed) 'Green'
    Write-PowerPlansStatus ("  [+] NVIDIA: power max={0}; graphics clock lock={1}; memory clock lock={2}; boost slider max={3}" -f $nvidiaResult.PowerLimitSet, $nvidiaResult.GraphicsClockLocked, $nvidiaResult.MemoryClockLocked, $nvidiaResult.BoostSliderSet) 'Green'
    Write-PowerPlansStatus ("  [+] AMD vendor: 3D V-Cache service status={0}; Ryzen Master CLI={1}" -f $amdResult.VCacheService, $amdResult.RyzenMasterCli) 'Green'
    if (-not $NoStartupTask -and -not $Silent) {
        if ($taskInstallResult.BootInstalled -and $taskInstallResult.GuardInstalled) {
            Write-PowerPlansStatus ("  [+] Startup permanence: hidden boot task and hidden recurring guard installed") 'Green'
        } elseif ($taskInstallResult.BootInstalled) {
            Write-PowerPlansStatus ("  [!] Startup permanence: hidden boot task installed; recurring guard registration failed") 'Yellow'
        } else {
            Write-PowerPlansStatus ("  [!] Startup permanence: task registration failed; plan remains active now") 'Yellow'
        }
    }

    if ($active.Count -eq 0 -or $active[0].Guid -ne $schemeGuid) {
        throw 'Ultimate power plan was not active after apply.'
    }

    if ($failedCount -gt 0) {
        Write-PowerPlansStatus ("  [!] Failed settings: {0}" -f ($failedLabels -join ', ')) 'Yellow'
        Write-PowerPlansStatus '  [!] Some supported settings failed to apply; run as Administrator to force machine-level policy settings.' 'Yellow'
    }

    if ($mismatchCount -gt 0) {
        Write-PowerPlansStatus ("  [!] Readback mismatches: {0}" -f ($mismatchLabels -join ', ')) 'Yellow'
        throw 'One or more power settings did not verify after apply.'
    }

    Write-PowerPlansStatus 'NUCLEAR PERFORMANCE ACTIVE - ALL SUPPORTED MAX SETTINGS APPLIED' 'Red'

    $summary = [pscustomobject]@{
        PlanName = $PlanName
        PlanGuid = $schemeGuid
        Active = $true
        SupportedSettingsSet = $setCount
        UnsupportedSettingsSkipped = $unsupportedCount
        FailedSettings = $failedCount
        FailedSettingLabels = ($failedLabels -join ', ')
        VerifiedSettings = $verifiedCount
        VerificationMismatches = $mismatchCount
        VerificationMismatchLabels = ($mismatchLabels -join ', ')
        UnsupportedProbeCount = $unsupportedEvidence.Count
        UnsupportedProbeLabels = (($unsupportedEvidence | ForEach-Object { $_.Label }) -join ', ')
        ConflictTasksDisabled = $conflictsDisabled.Count
        ConflictTaskNames = (($conflictsDisabled | ForEach-Object { $_.Name }) -join ', ')
        NetworkLowPowerSettingsChanged = $networkResult.Changed
        NetworkLowPowerSettingsVerified = $networkResult.Verified
        NetworkLowPowerUnsupported = $networkResult.Unsupported
        StartupTaskInstalled = ($taskInstallResult.BootInstalled -and $taskInstallResult.GuardInstalled)
        StartupBootTaskInstalled = $taskInstallResult.BootInstalled
        StartupGuardTaskInstalled = $taskInstallResult.GuardInstalled
        StartupBootTaskName = $BootTaskName
        StartupGuardTaskName = $GuardTaskName
        StartupVbsPath = $StartupVbsPath
        StartupScriptPath = $StartupScriptPath
        PersistedPlanGuidPath = $PlanGuidPath
        NvidiaStatus = $nvidiaResult.Status
        NvidiaPowerLimitSet = $nvidiaResult.PowerLimitSet
        NvidiaGraphicsClockLocked = $nvidiaResult.GraphicsClockLocked
        NvidiaMemoryClockLocked = $nvidiaResult.MemoryClockLocked
        NvidiaBoostSliderSet = $nvidiaResult.BoostSliderSet
        AmdVCacheService = $amdResult.VCacheService
        AmdRyzenMasterCli = $amdResult.RyzenMasterCli
        AmdRyzenMasterDriverCli = $amdResult.RyzenMasterDriverCli
    }

    if (-not $Silent) {
        $summary
    }
}

Apply-UltimatePowerPlan
