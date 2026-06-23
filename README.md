# Codex Ultimate Nuclear Performance Power Plan

PowerShell 5-compatible helper for the `POWERPLANS` profile command.

It creates or reuses the `Codex_Ultimate_Nuclear_Performance` Windows power plan, applies supported maximum-performance `powercfg` settings for AC and DC, disables sleep/hibernate/display/disk timeouts, and installs a hidden `wscript.exe` logon task so the plan is reapplied without terminal popups.

## Usage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PowerPlansUltimate.ps1
```

Quiet startup/task mode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PowerPlansUltimate.ps1 -Silent
```

Apply without registering the startup task:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PowerPlansUltimate.ps1 -NoStartupTask
```

## Verification

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-PowerPlansUltimate.ps1
```
