#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Optimize-RDSHost.ps1 - tunes a Windows Server session host for RDP / TSplus users.

.DESCRIPTION
    Applies a curated set of registry, service and policy changes that improve the interactive
    experience for 5-15 concurrent remote users, with WAN users as the default assumption.

    Supports Windows Server 2019, 2022 and 2025. Detects the OS and adapts. Refuses to run on
    client Windows or on unsupported server builds.

    Every change is explained before it is made, the prior value is recorded, and a rollback
    script is written to C:\ProgramData\RDSOptimize\ so the whole run can be reversed.

    Decisions that depend on your environment are asked interactively at run time, or taken
    from the defaults when -Unattended is used.

.PARAMETER Unattended
    Skip all prompts and use the documented defaults (WAN-optimised, nothing that breaks
    connectivity, audio/video/printing left intact).

.PARAMETER WhatIf
    Show what would change without changing anything. Also skips the reboot prompt.

.PARAMETER NoReboot
    Do not offer a reboot at the end (some changes need one - the script tells you which).

.PARAMETER InstallUpdates
    Scan Windows Update with the built-in Windows Update Agent and install pending updates at the end of the
    run. Interactive runs ask; this switch makes the answer Yes (and is the only way to get it with -Unattended).
    With -WhatIf the pending updates are listed but nothing is downloaded.

.PARAMETER UpdateDay
    Maintenance window day for scheduled update installs and restarts (step 13): 0 = every day, 1 = Sunday
    (default) ... 7 = Saturday. Used by the first two Windows Update behaviour options.

.PARAMETER UpdateHour
    Maintenance window hour, local time, 0-23. Default 3 (03:00).

.EXAMPLE
    # Download and run interactively
    Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/vpscloud-au/rds-host-tuning/v1.1.0/Optimize-RDSHost.ps1 -OutFile $env:TEMP\Optimize-RDSHost.ps1
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & $env:TEMP\Optimize-RDSHost.ps1

.EXAMPLE
    # One-liner straight from the web server, unattended, and patch the host while you are at it
    & ([ScriptBlock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/vpscloud-au/rds-host-tuning/v1.1.0/Optimize-RDSHost.ps1))) -Unattended -InstallUpdates

.EXAMPLE
    # Dry run
    .\Optimize-RDSHost.ps1 -WhatIf

.NOTES
    Version : 1.1.0  (2026-10-08)
    Source  : https://github.com/vpscloud-au/rds-host-tuning
    Author  : VPSCloud Australia
    Tested  : -WhatIf verified on Server 2025 (26100.6584) under PowerShell 5.1; 2019 (17763) and 2022 (20348) pending
    Log     : C:\ProgramData\RDSOptimize\Optimize-RDSHost_<timestamp>.log
    Rollback: C:\ProgramData\RDSOptimize\Rollback_<timestamp>.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Unattended,
    [switch]$NoReboot,
    [switch]$InstallUpdates,
    [ValidateRange(0, 7)][int]$UpdateDay = 1,
    [ValidateRange(0, 23)][int]$UpdateHour = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# #Requires is ignored when the script is run via Invoke-RestMethod | ScriptBlock, so check explicitly.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must run in an elevated (Run as Administrator) PowerShell session." -ForegroundColor Red
    return
}

# =====================================================================================
#  Infrastructure: logging, rollback, helpers
# =====================================================================================

$script:Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:WorkDir    = 'C:\ProgramData\RDSOptimize'
$script:LogFile    = Join-Path $WorkDir "Optimize-RDSHost_$Stamp.log"
$script:Rollback   = Join-Path $WorkDir "Rollback_$Stamp.ps1"
$script:RollbackLines = New-Object System.Collections.Generic.List[string]
$script:HiveRollback  = @{}          # hive key -> List[string] of rollback lines for that loaded hive
$script:HiveFiles     = @{}          # hive key -> NTUSER.DAT path
$script:RebootNeeded  = $false
$script:RebootReasons = New-Object System.Collections.Generic.List[string]
$script:ChangeCount   = 0
$script:WarnCount     = 0
$script:GpoManaged    = @{}          # "KEY\VALUE" (upper case, HKLM-relative) -> label of the GPO that owns it
$script:DryRun        = $WhatIfPreference

if (-not $DryRun) {
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $LogFile -Append | Out-Null
}

# Get-CimInstance auto-loads the CimCmdlets module, and its alias exports go through ShouldProcess: under -WhatIf
# that prints a dozen "What if: Set Alias" lines before the banner. Import it once with WhatIf temporarily off.
$savedWhatIf = $WhatIfPreference; $WhatIfPreference = $false
Import-Module CimCmdlets -ErrorAction SilentlyContinue
$WhatIfPreference = $savedWhatIf

function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 90) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 90) -ForegroundColor DarkCyan
}

# Console width for word-wrapping. Falls back to 100 when the host has no window (remoting, odd hosts).
function Get-ConsoleWidth {
    $w = 0
    try { $w = $Host.UI.RawUI.WindowSize.Width } catch { }
    if (-not $w -or $w -lt 60) { try { $w = $Host.UI.RawUI.BufferSize.Width } catch { } }
    if (-not $w -or $w -lt 60) { $w = 100 }
    if ($w -gt 130) { $w = 130 }
    return [int]$w
}

# Re-flow explanatory text to the console width. Single newlines inside a paragraph become spaces; a blank line
# or a line starting with '- ' starts a new paragraph (bullets keep a hanging indent). The source text can be
# hard-wrapped for readability without that wrapping leaking into the terminal.
function Write-Wrapped {
    param([string]$Text, [int]$Indent = 5, [ConsoleColor]$Color = 'Gray')
    $width = (Get-ConsoleWidth) - $Indent - 1
    if ($width -lt 40) { $width = 40 }
    $pad = ' ' * $Indent
    $paras = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($line in (($Text -replace "`r", '') -split "`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t -like '- *') { if ($cur) { $paras.Add($cur) }; $cur = $t }
        elseif ($cur) { $cur = "$cur $t" } else { $cur = $t }
    }
    if ($cur) { $paras.Add($cur) }
    foreach ($para in $paras) {
        $hang = if ($para -like '- *') { '  ' } else { '' }
        $out = New-Object System.Collections.Generic.List[string]
        $lineOut = ''
        foreach ($word in ($para -split ' +')) {
            if ($lineOut -eq '') { $lineOut = $word; continue }
            $prefixLen = if ($out.Count -gt 0) { $hang.Length } else { 0 }
            if (($lineOut.Length + 1 + $word.Length + $prefixLen) -gt $width) { $out.Add($lineOut); $lineOut = $word }
            else { $lineOut = "$lineOut $word" }
        }
        if ($lineOut -ne '') { $out.Add($lineOut) }
        for ($i = 0; $i -lt $out.Count; $i++) {
            Write-Host ($pad + $(if ($i -gt 0) { $hang } else { '' }) + $out[$i]) -ForegroundColor $Color
        }
    }
}

function Write-Step {
    param([int]$Number, [string]$Title, [string]$Why)
    Write-Host ''
    Write-Host ("[{0,2}] {1}" -f $Number, $Title) -ForegroundColor Yellow
    Write-Wrapped $Why -Indent 5 -Color Gray
}

function Write-Result { param([string]$Text) Write-Host "     => $Text" -ForegroundColor Green }
function Write-Skip   { param([string]$Text) Write-Host "     -- Skipped: $Text" -ForegroundColor DarkGray }
function Write-Warn   { param([string]$Text) $script:WarnCount++; Write-Host "     !! $Text" -ForegroundColor Magenta }
function Write-Info   { param([string]$Text) Write-Host "     .. $Text" -ForegroundColor DarkGray }

# Native commands (reg.exe, query.exe) write to stderr on failure; under $ErrorActionPreference='Stop'
# that becomes a terminating error. Running them through cmd.exe sidesteps it and gives a clean exit code.
function Invoke-RegLoad   { param([string]$Key, [string]$File) $out = cmd /c "reg load `"$Key`" `"$File`" 2>&1"; return @{ Ok = ($LASTEXITCODE -eq 0); Out = ($out -join ' ') } }
function Invoke-RegUnload { param([string]$Key) [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300; $null = cmd /c "reg unload `"$Key`" 2>&1"; return ($LASTEXITCODE -eq 0) }
function Get-OtherSessionCount {
    $rows = @(cmd /c "query user 2>nul" | Select-Object -Skip 1)
    $n = $rows.Count - 1
    if ($n -lt 0) { $n = 0 }
    return $n
}

function Add-RebootReason { param([string]$Reason) $script:RebootNeeded = $true; if (-not $RebootReasons.Contains($Reason)) { $RebootReasons.Add($Reason) } }

# Read one registry value by exact name. Get-ItemProperty -Name treats '*' and '?' as wildcards and strict mode
# throws on a missing property, so read the whole key and index the property collection. $null = key or value absent.
function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Read the one value through .NET. Get-ItemProperty marshals the whole key and throws 'Specified cast is not
    # valid' on keys that hold an oddly-sized value (the Group Policy history keys do), even with -ErrorAction.
    $k = $null
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    } catch { return $null }
    finally { if ($null -ne $k) { $k.Close() } }
}

# Human-readable form of a Terminal Services time limit stored in milliseconds.
function Format-Ms {
    param($Ms)
    if ($null -eq $Ms) { return 'not configured' }
    $v = [int64]$Ms
    if ($v -eq 0) { return 'never (0)' }
    $m = $v / 60000
    if ($m -ge 60) { return ('{0:0.#} h' -f ($m / 60)) } else { return ('{0:0} min' -f $m) }
}

# Group Policy awareness. Registry-based policy arrives as registry.pol files ([MS-GPREG] "PReg" format). The
# Registry client-side extension records every GPO it applied, with its SYSVOL path, under its History key, and
# Windows also caches the files under System32\GroupPolicy\DataStore. Reading them tells us exactly which
# key/value pairs Group Policy owns on this host, so the script skips those instead of fighting the next refresh.
function Read-RegistryPol {
    param([string]$File, [string]$Label)
    try {
        $b = [IO.File]::ReadAllBytes($File)
        if ($b.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'PReg') { return }
        $pos = 8
        # Each record: '[' key NUL ';' value NUL ';' type(4 bytes) ';' size(4 bytes) ';' data ']'  - text is UTF-16LE
        while ($pos + 2 -le $b.Length -and [BitConverter]::ToUInt16($b, $pos) -eq 0x5B) {
            $pos += 2
            $end = $pos; while ($end + 1 -lt $b.Length -and [BitConverter]::ToUInt16($b, $end) -ne 0) { $end += 2 }
            $key = [Text.Encoding]::Unicode.GetString($b, $pos, $end - $pos); $pos = $end + 4
            $end = $pos; while ($end + 1 -lt $b.Length -and [BitConverter]::ToUInt16($b, $end) -ne 0) { $end += 2 }
            $val = [Text.Encoding]::Unicode.GetString($b, $pos, $end - $pos); $pos = $end + 4
            $pos += 6
            $size = [BitConverter]::ToInt32($b, $pos); $pos += 6
            $pos += $size + 2
            if ($val -like '**Del.*') { $val = $val.Substring(6) }      # "delete this value" entries own it just the same
            if ($val -and -not $val.StartsWith('**')) { $script:GpoManaged[("$key\$val").ToUpperInvariant()] = $Label }
        }
    } catch { }
}

# Label of the GPO that owns an HKLM value, or $null. Only machine policy is tracked.
function Test-GpoManaged {
    param([string]$Path, [string]$Name)
    if ($script:GpoManaged.Count -eq 0) { return $null }
    if ($Path -match '^(HKLM:|Registry::HKEY_LOCAL_MACHINE)\\(.+)$') {
        $k = ("$($Matches[2])\$Name").ToUpperInvariant()
        if ($script:GpoManaged.ContainsKey($k)) { return $script:GpoManaged[$k] }
    }
    return $null
}

# Ask a yes/no question. Returns [bool]. Honours -Unattended via $Default.
function Ask-YesNo {
    param([string]$Question, [bool]$Default = $true, [string]$Detail = '')
    if ($Detail) { Write-Wrapped $Detail -Indent 5 -Color DarkGray }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    if ($Unattended) {
        Write-Host "     ?  $Question $hint  -> (unattended) $(if ($Default) {'Yes'} else {'No'})" -ForegroundColor White
        return $Default
    }
    while ($true) {
        $r = Read-Host "     ?  $Question $hint"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        if ($r -match '^(y|yes)$') { return $true }
        if ($r -match '^(n|no)$')  { return $false }
    }
}

# Ask a multiple-choice question. $Choices is an ordered array of strings; returns the index chosen.
function Ask-Choice {
    param([string]$Question, [string[]]$Choices, [int]$Default = 0, [string]$Detail = '')
    if ($Detail) { Write-Wrapped $Detail -Indent 5 -Color DarkGray }
    Write-Host "     ?  $Question" -ForegroundColor White
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        $mark = if ($i -eq $Default) { '*' } else { ' ' }
        Write-Host ("        {0} {1}) {2}" -f $mark, ($i + 1), $Choices[$i]) -ForegroundColor White
    }
    if ($Unattended) { Write-Host "        -> (unattended) option $($Default + 1)" -ForegroundColor White; return $Default }
    while ($true) {
        $r = Read-Host "        Choose 1-$($Choices.Count) (default $($Default + 1))"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $Choices.Count) { return ([int]$r - 1) }
    }
}

# Set a registry value, recording the prior state for rollback.
function Set-RegValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','ExpandString','Binary','QWord','MultiString')][string]$Type = 'DWord',
        [string]$Describe = ''
    )
    $existing = Get-RegValue $Path $Name
    $existed  = ($null -ne $existing)

    # Path inside a user hive that is not loaded (dry run): the current value cannot be read.
    $hiveKey = $null
    if ($Path -match '^Registry::(HKU\\RDSOPT_[^\\]+)') { $hiveKey = $Matches[1] }
    $hiveUnloaded = ($null -ne $hiveKey) -and -not (Test-Path -LiteralPath "Registry::$hiveKey")

    # Already correct? Say so and move on.
    $same = $false
    if ($existed) {
        if ($Type -eq 'Binary') { $same = (@(Compare-Object ([byte[]]$existing) ([byte[]]$Value)).Count -eq 0) }
        else { $same = ("$existing" -eq "$Value") }
    }
    $label = if ($Describe) { $Describe } else { "$Name" }
    $shown = if ($Type -eq 'Binary') { ($Value | ForEach-Object { '{0:x2}' -f $_ }) -join ',' } else { "$Value" }
    $gpo   = Test-GpoManaged $Path $Name
    if ($same) { Write-Info "$label already = $shown (no change$(if ($gpo) { "; set by $gpo" }))"; return }

    $was   = if ($existed) { if ($Type -eq 'Binary') { ($existing | ForEach-Object { '{0:x2}' -f $_ }) -join ',' } else { "$existing" } }
             elseif ($hiveUnloaded) { '<unknown - hive not loaded in dry run>' } else { '<not set>' }

    # Owned by a GPO: whatever is written here is put back at the next policy refresh. Say so and leave it.
    if ($gpo) {
        Write-Warn "$label is controlled by $gpo (currently $was) - skipped. Change it in that GPO; anything written here is overwritten at the next policy refresh."
        return
    }

    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $shown (was $was)")) {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
    $script:ChangeCount++
    Write-Result "$label : $was -> $shown"

    # Rollback line (lines for a loaded user hive are grouped so the rollback can reload that hive first)
    $escPath = $Path -replace "'", "''"
    $target = $RollbackLines
    if ($null -ne $hiveKey) {
        if (-not $script:HiveRollback.ContainsKey($hiveKey)) { $script:HiveRollback[$hiveKey] = New-Object System.Collections.Generic.List[string] }
        $target = $script:HiveRollback[$hiveKey]
    }
    if ($existed) {
        $rbVal = if ($Type -eq 'Binary') { '([byte[]](' + (($existing | ForEach-Object { "0x{0:x2}" -f $_ }) -join ',') + '))' }
                 elseif ($Type -in 'String','ExpandString') { "'" + ("$existing" -replace "'", "''") + "'" }
                 else { "$existing" }
        $target.Add("New-ItemProperty -LiteralPath '$escPath' -Name '$Name' -Value $rbVal -PropertyType $Type -Force | Out-Null")
    } else {
        $target.Add("Remove-ItemProperty -LiteralPath '$escPath' -Name '$Name' -ErrorAction SilentlyContinue")
    }
}

# Set a service startup type (and stop it if disabling), recording rollback.
function Set-ServiceState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Name, [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType, [switch]$StopNow, [string]$Describe = '')
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Info "Service $Name not present on this host (skipped)"; return }
    $cur = (Get-CimInstance Win32_Service -Filter "Name='$Name'").StartMode   # Auto / Manual / Disabled
    $curNorm = switch ($cur) { 'Auto' { 'Automatic' } default { $cur } }
    $label = if ($Describe) { $Describe } else { $Name }
    if ($curNorm -eq $StartupType -and -not ($StopNow -and $svc.Status -eq 'Running')) { Write-Info "$label already $StartupType (no change)"; return }
    if ($PSCmdlet.ShouldProcess("Service $Name", "StartupType $curNorm -> $StartupType$(if ($StopNow) {', stop now'})")) {
        Set-Service -Name $Name -StartupType $StartupType
        if ($StopNow -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    }
    $script:ChangeCount++
    Write-Result "$label : $curNorm -> $StartupType$(if ($StopNow) {' (stopped)'})"
    $RollbackLines.Add("Set-Service -Name '$Name' -StartupType $curNorm -ErrorAction SilentlyContinue")
}

function Set-ScheduledTaskState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TaskPath, [string]$TaskName, [bool]$Enabled, [string]$Describe = '')
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Info "Task $TaskPath$TaskName not present (skipped)"; return }
    $label = if ($Describe) { $Describe } else { "$TaskPath$TaskName" }
    $isEnabled = ($t.State -ne 'Disabled')
    if ($isEnabled -eq $Enabled) { Write-Info "$label already $(if ($Enabled) {'enabled'} else {'disabled'}) (no change)"; return }
    if ($PSCmdlet.ShouldProcess("Task $TaskPath$TaskName", "$(if ($Enabled) {'Enable'} else {'Disable'})")) {
        if ($Enabled) { Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName | Out-Null }
        else          { Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName | Out-Null }
    }
    $script:ChangeCount++
    Write-Result "$label : $(if ($Enabled) {'enabled'} else {'disabled'})"
    $RollbackLines.Add("$(if ($Enabled) {'Disable'} else {'Enable'})-ScheduledTask -TaskPath '$TaskPath' -TaskName '$TaskName' -ErrorAction SilentlyContinue | Out-Null")
}

# Registry roots used throughout
$TS_POL   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$TS_SYS   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$TS_WS    = "$TS_SYS\WinStations"
$TS_RDP   = "$TS_WS\RDP-Tcp"
$WS_POL   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'

# =====================================================================================
#  0. Pre-flight
# =====================================================================================

Write-Banner "Optimize-RDSHost v1.1.0 - session host tuning for RDP / TSplus  ($(if ($DryRun) {'DRY RUN'} else {'LIVE'}))"
Write-Host "  Log      : $LogFile"
Write-Host "  Rollback : $Rollback"
Write-Host "  Mode     : $(if ($Unattended) {'Unattended (defaults)'} else {'Interactive'})"

$os    = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$ubr   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
$cs    = Get-CimInstance Win32_ComputerSystem

if ($os.ProductType -eq 1) {
    Write-Host ''
    Write-Host "  This is a client OS ($($os.Caption)). This script is for Windows Server session hosts only. Exiting." -ForegroundColor Red
    if (-not $DryRun) { Stop-Transcript | Out-Null }
    return
}

$osName = switch ($build) {
    17763 { 'Windows Server 2019' }
    20348 { 'Windows Server 2022' }
    26100 { 'Windows Server 2025' }
    default { $null }
}
if (-not $osName) {
    Write-Host ''
    Write-Host "  Unsupported server build $build ($($os.Caption)). Supported: 2019 (17763), 2022 (20348), 2025 (26100). Exiting." -ForegroundColor Red
    if (-not $DryRun) { Stop-Transcript | Out-Null }
    return
}

$isVM     = ($cs.Model -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|HVM')
$domainJoined = [bool]$cs.PartOfDomain
$hasGPU   = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft (Basic|Hyper-V|Remote)|VMware SVGA|VirtualBox|Standard VGA' }).Count -gt 0
$tsplus   = (Test-Path 'C:\Program Files (x86)\TSplus') -or (Test-Path 'C:\Program Files\TSplus') -or (@(Get-Service -Name '*tsplus*' -ErrorAction SilentlyContinue).Count -gt 0)
$sqlLocal = @(Get-Service -Name 'MSSQL$*','MSSQLSERVER' -ErrorAction SilentlyContinue | Where-Object { $_.StartType -ne 'Disabled' }).Count -gt 0
$rdsRole  = (Get-WindowsFeature -Name RDS-RD-Server -ErrorAction SilentlyContinue).Installed
$defender = $null; try { $defender = Get-MpComputerStatus -ErrorAction Stop } catch { }
$lastCU   = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.HotFixID -match '^KB' -and $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
$wsearchStart = 'absent'
if (Get-Service -Name 'WSearch' -ErrorAction SilentlyContinue) {
    $wsearchStart = (Get-CimInstance Win32_Service -Filter "Name='WSearch'").StartMode
    if ($wsearchStart -eq 'Auto') { $wsearchStart = 'Automatic' }
}

# Which of the policy values below does Group Policy already own? Read every applied GPO's registry.pol.
$gpoHistory = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History\{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
$gpoCache   = Join-Path $env:SystemRoot 'System32\GroupPolicy\DataStore'
$gpoCount   = 0
try {
    if (Test-Path $gpoHistory) {
        foreach ($h in @(Get-ChildItem -Path $gpoHistory -ErrorAction SilentlyContinue)) {
            $fsp = Get-RegValue $h.PSPath 'FileSysPath'; $dn = Get-RegValue $h.PSPath 'DisplayName'; $gn = Get-RegValue $h.PSPath 'GPOName'
            if (-not $fsp) { continue }
            $glabel = if ($dn) { "GPO '$dn'" } elseif ($gn) { "GPO $gn" } else { 'a GPO' }
            $pol = $null
            try { $cand = Join-Path $fsp 'registry.pol'; if (Test-Path -LiteralPath $cand) { $pol = $cand } } catch { }
            if (-not $pol -and $gn -and (Test-Path $gpoCache)) {
                $pol = Get-ChildItem -Path $gpoCache -Recurse -Filter 'registry.pol' -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -like "*$gn*\Machine\registry.pol" } | Select-Object -First 1 -ExpandProperty FullName
            }
            if ($pol) { Read-RegistryPol $pol $glabel; $gpoCount++ }
        }
    }
} catch { Write-Host "    .. Group Policy scan skipped: $($_.Exception.Message)" -ForegroundColor DarkGray }

Write-Host ''
Write-Host "  Detected" -ForegroundColor Cyan
Write-Host ("    OS            : {0}  build {1}.{2}" -f $osName, $build, $ubr)
Write-Host ("    Hardware      : {0}{1}" -f $cs.Model, $(if ($isVM) { '  (virtual machine)' } else { '' }))
Write-Host ("    GPU           : {0}" -f $(if ($hasGPU) { 'dedicated GPU present' } else { 'none - software RDP encoding' }))
Write-Host ("    RDS role      : {0}" -f $(if ($rdsRole) { 'RD Session Host installed' } else { 'not installed (admin-only RDP or TSplus)' }))
Write-Host ("    TSplus        : {0}" -f $(if ($tsplus) { 'detected' } else { 'not detected' }))
Write-Host ("    SQL Server    : {0}" -f $(if ($sqlLocal) { 'local instance running - scheduler choice will be asked' } else { 'none local' }))
Write-Host ("    Defender      : {0}" -f $(if ($defender -and $defender.RealTimeProtectionEnabled) { 'real-time protection on' } else { 'off / not present' }))
Write-Host ("    Windows Search: {0}" -f $(if ($wsearchStart -eq 'absent') { 'service not present' } elseif ($wsearchStart -eq 'Disabled') { 'service Disabled (Search Service feature not installed, or switched off)' } else { "service $wsearchStart" }))
Write-Host ("    Domain        : {0}" -f $(if ($domainJoined) { "$($cs.Domain) - domain-joined; Group Policy can override any policy key below" } else { 'none (workgroup / standalone)' }))
Write-Host ("    Group Policy  : {0}" -f $(if ($script:GpoManaged.Count) { "$gpoCount GPO(s) deliver registry policy here; $($script:GpoManaged.Count) value(s) are GPO-controlled - conflicts are flagged per step" } else { 'no registry policy from GPOs found on this host' }))
Write-Host ("    Last update   : {0}" -f $(if ($lastCU) { "$($lastCU.HotFixID) on $($lastCU.InstalledOn.ToString('yyyy-MM-dd'))" } else { 'unknown' }))
Write-Host ("    Sessions now  : {0} other user session(s)" -f (Get-OtherSessionCount))

# ---- Known-issue checks per OS -------------------------------------------------------------
Write-Host ''
Write-Host "  Known-issue checks" -ForegroundColor Cyan
switch ($build) {
    26100 {
        # Feb 2025 CU (KB5051987, UBR 3194) froze RDP sessions shortly after connect. Fixed by KB5055523 (April 2025, UBR 3775).
        if ($ubr -ge 3194 -and $ubr -lt 3775) {
            Write-Warn "Server 2025 build 26100.$ubr is in the range affected by the Feb-2025 RDP freeze regression (KB5051987). Install the April 2025 CU (KB5055523, 26100.3775) or later BEFORE relying on this host. No tuning here fixes that bug - answer Yes to the Windows Update question (or run with -InstallUpdates) and this run will install it."
        } elseif ($ubr -lt 3194) {
            Write-Warn "Server 2025 build 26100.$ubr predates Feb 2025 - this host has not been patched in a long time. Patch it."
        } else {
            Write-Host "    OK   Server 2025 build 26100.$ubr is past the Feb/Mar-2025 RDP freeze regression." -ForegroundColor Green
        }
        Write-Host "    Note Server 2025 ships the Windows 11 shell and Edge first-run experience; the consumer-feature cleanup in step 9 matters most here." -ForegroundColor DarkGray
    }
    20348 {
        Write-Host "    OK   Server 2022 - no RDP-specific regressions tracked for the session-host role." -ForegroundColor Green
        Write-Host "    Note If this host is also an RD Gateway, early-2024 CUs caused RDG service crashes on UDP 3391; ensure it is current." -ForegroundColor DarkGray
    }
    17763 {
        Write-Host "    OK   Server 2019 - mature. Some Server 2025-specific consumer-feature keys are harmless no-ops here and will be skipped." -ForegroundColor Green
        Write-Warn "Server 2019 is in extended support only. Plan the move."
    }
}
if ($lastCU -and $lastCU.InstalledOn -lt (Get-Date).AddDays(-90)) {
    Write-Warn "Last update installed $([int]((Get-Date) - $lastCU.InstalledOn).TotalDays) days ago. This host is behind on cumulative updates - the Windows Update question below (or -InstallUpdates) can fix that in this run."
}
if ($tsplus) {
    Write-Host "    Note TSplus detected. This script does NOT touch TSplus's own configuration (AdminTool settings, HTML5 gateway, Universal Printer). Set session timeouts in ONE place - see step 4." -ForegroundColor DarkGray
}
if ($domainJoined) {
    Write-Wrapped "Note Domain-joined. This script writes the same HKLM\SOFTWARE\Policies keys a GPO writes. Anything a GPO also configures is re-applied at the next policy refresh (at boot and every 90 minutes) and the GPO wins, so those values are flagged and skipped below - change them in the GPO. After a live run, do 'gpupdate /force' and run this script again with -WhatIf: anything that shows as changing again is GPO-controlled and was missed." -Indent 4 -Color DarkGray
}
if ($rdsRole -eq $false -and -not $tsplus) {
    Write-Warn "Neither the RD Session Host role nor TSplus is present. Without one, this server only allows 2 admin RDP sessions. The tuning still applies, but confirm this is the right box."
}

Write-Host ''
if (-not (Ask-YesNo "Proceed with tuning this host?" $true)) {
    Write-Host "  Aborted by operator. Nothing changed." -ForegroundColor Yellow
    if (-not $DryRun) { Stop-Transcript | Out-Null }
    return
}

# =====================================================================================
#  Decisions (asked up front so the run is uninterrupted after this point)
# =====================================================================================

Write-Banner "Decisions - answer once, the rest runs unattended"

$Decisions = [ordered]@{}

# --- Link type ---
$Decisions.Link = Ask-Choice "Where do most users connect from?" @(
    'WAN / internet (default - 24-bit colour, 30 fps, keep-alives, UDP on)',
    'LAN only (32-bit colour, 60 fps)') 0

# --- Transport ---
$Decisions.UDP = Ask-YesNo "Keep UDP transport enabled (TCP + UDP)?" $true `
    "UDP is a real win on lossy WAN links. If users later report periodic freezes or black screens,`nre-run with 'No' here as a diagnostic - that forces TCP-only. Do not start with TCP-only."

# --- Frame interval ---
$fpsDefault = ($Decisions.Link -eq 1)
$Decisions.Fps60 = Ask-YesNo "Raise the DWM frame rate cap from ~30 to ~60 fps?" $fpsDefault `
    "Makes scrolling and window dragging feel much smoother. Costs bandwidth and encoder CPU.`nRecommended on LAN; usually not worth it over WAN. Needs a reboot."

# --- Scheduler ---
$schedDetail = "0x26 = short quantum, foreground boost - favours the interactive user, standard RDS tuning.`n`n0x18 = Server default - favours background services."
if ($sqlLocal) { $schedDetail += "`n`nA LOCAL SQL Server instance was detected. SQL runs as a background service; 0x26 slightly deprioritises it under load. For 5-15 users with light SQL the interactive feel still wins, so the default stays 0x26 - choose 0x18 only if SQL is the primary workload on this box." }
$Decisions.Sched = Ask-Choice "Processor scheduling (Win32PrioritySeparation)?" @(
    'Foreground programs - 0x26 (default for session hosts)',
    'Background services - 0x18 (Server default; choose if local SQL is the primary workload)') 0 $schedDetail

# --- Windows Search ---
$Decisions.Search = Ask-Choice "Windows Search indexing?" @(
    'Restrict (default) - index only the Start menu/apps; no Outlook, no user profiles, no UNC/removable',
    'Disable the service entirely - users lose Outlook/Explorer search',
    'Leave as-is') 0 `
    "On a multi-user host, indexing every user's profile and Outlook OST is the classic hidden disk-I/O hog."
$Decisions.EnableSearchSvc = $false
if ($Decisions.Search -eq 0 -and $wsearchStart -eq 'Disabled') {
    $Decisions.EnableSearchSvc = Ask-YesNo "Windows Search service is currently DISABLED on this host. Enable it (installs the Windows Search Service feature)?" $false `
        "Restrict mode does not turn a disabled indexer on by itself. Without it, Outlook search goes to the mail server and Explorer search is slower but works. Enabling adds SearchIndexer.exe as a permanent background process; with the restrictions above it only indexes the Start menu and apps. Leave it off unless users are asking for it."
} elseif ($Decisions.Search -eq 0) {
    Write-Host "     .. Windows Search service is $wsearchStart - left as-is; only the indexing scope is restricted." -ForegroundColor DarkGray
}

# --- Session limits ---
$Decisions.DisconnectHrs = 0
$curMDT = Get-RegValue $TS_POL 'MaxDisconnectionTime'
$curMIT = Get-RegValue $TS_POL 'MaxIdleTime'
$curSSP = Get-RegValue $TS_POL 'fSingleSessionPerUser'
$sessDetail = "Disconnected sessions hold RAM, handles and open files indefinitely unless a limit ends them."
if ($tsplus) { $sessDetail += " TSplus AdminTool (Server > Group Policies) writes these same registry values and rewrites them whenever its settings are saved. Set the limit in ONE place only: if TSplus manages it, answer 0 here." }
$sessDetail += "`n`nCurrently on this host: disconnected-session limit = $(Format-Ms $curMDT), idle limit = $(Format-Ms $curMIT)."
if ($null -ne $curMDT -and [int64]$curMDT -gt 0 -and [int64]$curMDT -lt 600000) { $sessDetail += " A limit under 10 minutes logs users off after a short WAN blip and unsaved work is lost - make sure that is deliberate." }
$choice = Ask-Choice "End DISCONNECTED sessions after how long?" @(
    '2 hours', '4 hours (default)', '8 hours', '0 - do not set (TSplus or GPO manages it)') $(if ($tsplus) { 3 } else { 1 }) $sessDetail
$Decisions.DisconnectHrs = @(2, 4, 8, 0)[$choice]
$Decisions.SingleSession = Ask-YesNo "Restrict each user to a single session?" $true `
    "Stops the 'I have three sessions open' memory bloat. TSplus also expects this. Say No only if you deliberately run multi-session users.`n`nCurrently on this host: $(if ($null -eq $curSSP) { 'not configured (Windows default is one session per user)' } elseif ([int]$curSSP -eq 1) { 'single session enforced' } else { 'multiple sessions per user explicitly allowed - someone chose that' })."

# --- Redirection ---
$Decisions.DisableComLpt = Ask-YesNo "Disable COM and LPT port redirection?" $true `
    "Serial/parallel port redirection is almost never needed and each is a per-session virtual channel.`nAudio, microphone, camera, clipboard, drives and PRINTERS are all left ENABLED regardless of this answer."
$curRODP = Get-RegValue $TS_POL 'RedirectOnlyDefaultClientPrinter'
$Decisions.DefaultPrinterOnly = Ask-YesNo "Redirect ONLY the client's default printer (faster logon)?" ($null -ne $curRODP -and [int]$curRODP -eq 1) `
    "Cuts logon time where users have many local printers, but users lose access to their other printers inside the session. The default follows what the host does today, so printing never changes unless you say so. TSplus Universal Printer is unaffected either way.`n`nCurrently on this host: $(if ($null -eq $curRODP) { 'not configured - all client printers are redirected' } elseif ([int]$curRODP -eq 1) { 'ON - only the default client printer is redirected' } else { 'OFF - all client printers are redirected' })."

# --- Profiles ---
$Decisions.ProfileCleanupDays = 0
$choice = Ask-Choice "Delete LOCAL user profiles unused for how long?" @(
    '90 days (default)', '60 days', '30 days', 'Never - do not configure') 0 `
    "Profile bloat is the slow-death mode of session hosts. Roaming profiles are unaffected (their local cache is rebuilt from AD at next logon).`nUses the standard 'Delete user profiles older than a specified number of days on system restart' policy - it runs at boot, not live."
$Decisions.ProfileCleanupDays = @(90, 60, 30, 0)[$choice]

# --- Visual effects on existing profiles ---
$Decisions.VfxExisting = Ask-YesNo "Also apply the visual-effects settings to EXISTING user profiles?" $true `
    "New profiles inherit from the Default User hive automatically. Existing users keep their own settings unless this loads each`nunloaded NTUSER.DAT and sets them. Users currently logged on are skipped (their hive is in use)."

# --- Defender ---
$Decisions.DefenderExcl = $false
if ($defender -and $defender.RealTimeProtectionEnabled) {
    $Decisions.DefenderExcl = Ask-YesNo "Add Defender exclusions for TSplus / RDS paths?" $true `
        "Exclusions only - real-time protection stays on. Adds the TSplus program folder (if present) and the standard`nper-user browser-cache paths that generate thousands of tiny writes per session."
}

# --- Misc services ---
$Decisions.DisableSysMain = Ask-YesNo "Disable SysMain (Superfetch)?" $true "Tuned for single-user desktops; pointless on an SSD-backed multi-user VM."
$Decisions.DisableWER     = Ask-YesNo "Disable Windows Error Reporting?" $true "Stops crash-dialog stalls and dump collection inside user sessions."

# --- Windows Update behaviour ---
$WU_POL   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AU_POL   = "$WU_POL\AU"
$dayNames = @('every day', 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
$window   = '{0} {1:00}:00' -f $dayNames[$UpdateDay], $UpdateHour
$curAUO   = Get-RegValue $AU_POL 'AUOptions'
$curDay   = Get-RegValue $AU_POL 'ScheduledInstallDay'
$curHour  = Get-RegValue $AU_POL 'ScheduledInstallTime'
$curNoRb  = Get-RegValue $AU_POL 'NoAutoRebootWithLoggedOnUsers'
$curWsus  = if ((Get-RegValue $AU_POL 'UseWUServer') -eq 1) { Get-RegValue $WU_POL 'WUServer' } else { $null }
$auText   = if ($null -eq $curAUO) { 'not configured (Windows default: auto-install and restart outside active hours, on its own schedule)' }
            elseif ([int]$curAUO -eq 4) {
                $sched = ''
                if ($null -ne $curDay -and [int]$curDay -ge 0 -and [int]$curDay -le 7 -and $null -ne $curHour) { $sched = ' ' + $dayNames[[int]$curDay] + (' {0:00}:00' -f [int]$curHour) }
                "scheduled install$sched"
            }
            elseif ([int]$curAUO -eq 3) { 'auto download, notify to install' }
            elseif ([int]$curAUO -eq 2) { 'notify before download' }
            else { "option $curAUO" }
$rbText   = if ($null -eq $curNoRb) { 'not configured' } elseif ([int]$curNoRb -eq 1) { 'blocked' } else { 'allowed' }
$wuBehDetail = "A session host should patch at a predictable time and never restart in the working day. Active hours 06:00-20:00 are set by every option except 'leave as-is'. The window is $window - change it with -UpdateDay (0 = every day, 1 = Sunday .. 7 = Saturday) and -UpdateHour. WSUS, where present, still decides WHAT is approved; this decides WHEN it installs and restarts."
$wuBehDetail += "`n`nCurrently on this host: automatic updates = $auText; restart with users logged on = $rbText; source = $(if ($curWsus) { "WSUS $curWsus" } else { 'Microsoft Update' })."
$gpoAU = Test-GpoManaged $AU_POL 'AUOptions'
if ($gpoAU) { $wuBehDetail += " Automatic Updates is controlled by $gpoAU - choose 'leave as-is' unless you are changing that GPO." }
$Decisions.UpdateMode = Ask-Choice "Windows Update behaviour?" @(
    "Install in the window ($window) and restart then if needed - 15-minute warning to anyone still logged on (default)",
    "Install in the window ($window), restart only once nobody is logged on",
    'Download and notify only - an admin installs and restarts by hand',
    'Leave as-is (WSUS, GPO or RMM already manages it)') $(if ($gpoAU) { 3 } else { 0 }) $wuBehDetail

# --- Windows Update: install now ---
$wuDetail = "Uses the Windows Update Agent built into the OS - no modules, nothing extra downloaded. Lists what is pending, then downloads and installs it after the tuning changes (step 16). A cumulative update takes 10-30 minutes and needs a reboot. With -WhatIf it only lists. Updates are not covered by the rollback script (use 'wusa /uninstall /kb:NNNNNNN')."
if ($build -eq 26100 -and $ubr -lt 3775) { $wuDetail += "`n`nThis host is inside the Server 2025 RDP freeze range - the fix (KB5055523 or later) arrives as a pending cumulative update." }
if ($lastCU -and $lastCU.InstalledOn -lt (Get-Date).AddDays(-90)) { $wuDetail += "`n`nThis host is more than 90 days behind. Patching it is the single most effective step on this list." }
$Decisions.InstallUpdates = Ask-YesNo "Scan Windows Update and install pending updates at the end of this run?" ([bool]$InstallUpdates) $wuDetail

Write-Host ''
Write-Host "  Decisions recorded. Applying." -ForegroundColor Cyan
Start-Sleep -Seconds 1

# =====================================================================================
#  1. RDP graphics pipeline
# =====================================================================================

Write-Banner "Applying changes"

Write-Step 1 "RDP graphics pipeline" `
"Server-side policy keys that cap what the encoder has to do. Wallpaper removal is the single biggest bandwidth
saving. Colour depth and image quality are pinned so neither a GPO nor a client .rdp file can push them to lossless.
H.264/AVC444 is NOT forced - without a GPU that costs roughly one vCPU per active session for no gain."

Set-RegValue $TS_POL 'fNoRemoteDesktopWallpaper' 1 -Describe 'Enforce removal of remote desktop wallpaper'
Set-RegValue $TS_POL 'ColorDepth' $(if ($Decisions.Link -eq 0) { 3 } else { 4 }) -Describe "Max colour depth ($(if ($Decisions.Link -eq 0) {'24-bit, WAN'} else {'32-bit, LAN'}))"
Set-RegValue $TS_POL 'ImageQuality' 2 -Describe 'RemoteFX adaptive graphics image quality (Medium)'
Set-RegValue $TS_POL 'MaxCompressionLevel' 2 -Describe 'RDP compression (balanced)'
Set-RegValue $TS_POL 'AVC444ModePreferred' 0 -Describe 'Prioritise H.264/AVC444 (off)'
if ($hasGPU) {
    Write-Warn "A dedicated GPU was detected. Leaving 'Use hardware graphics adapters' and AVC hardware encode at their current values - review manually: a GPU host SHOULD use them."
} else {
    Set-RegValue $TS_POL 'bEnumerateHWBeforeSW' 0 -Describe 'Use hardware graphics adapters (off - no GPU)'
}
Set-RegValue $TS_POL 'fEnableTimeZoneRedirection' 1 -Describe 'Time zone redirection (users see their own local time)'

# =====================================================================================
#  2. Transport / frame rate / keep-alive
# =====================================================================================

Write-Step 2 "Transport, frame rate and keep-alive" `
"SelectTransport 0 = TCP+UDP, 1 = TCP only. Keep-alive every 1 minute lets the server detect a dropped WAN link
promptly instead of leaving a zombie session holding the user's licence and files. The DWM frame interval is the
one tweak users actually notice (15 ms ~ 60 fps); it needs a reboot."

Set-RegValue $TS_POL 'SelectTransport' $(if ($Decisions.UDP) { 0 } else { 1 }) -Describe "RDP transport ($(if ($Decisions.UDP) {'TCP + UDP'} else {'TCP only'}))"
Set-RegValue $TS_POL 'KeepAliveEnable' 1 -Describe 'Keep-alive connections'
Set-RegValue $TS_POL 'KeepAliveInterval' 1 -Describe 'Keep-alive interval (minutes)'
Set-RegValue $TS_POL 'fDisableAutoReconnect' 0 -Describe 'Automatic reconnection (allowed)'
if ($Decisions.Fps60) {
    Set-RegValue $TS_WS 'DWMFRAMEINTERVAL' 15 -Describe 'DWM frame interval (15 ms ~ 60 fps)'
    Add-RebootReason 'DWMFRAMEINTERVAL (frame rate cap)'
} else {
    Write-Skip "DWM frame interval left at default (~30 fps) - right choice for WAN users."
}

# =====================================================================================
#  3. Device redirection
# =====================================================================================

Write-Step 3 "Device redirection" `
"Each redirection channel is a per-session virtual-channel thread and adds logon latency. COM/LPT are removed by
default. Audio playback, microphone, camera, clipboard, drive and PRINTER redirection are explicitly left enabled -
Teams/video in-session and client printing both depend on them. Easy Print is preferred first so client printers
don't need matching drivers on the host; an Easy Print choice already made by an operator, GPO or TSplus is left alone."

if ($Decisions.DisableComLpt) {
    Set-RegValue $TS_POL 'fDisableCcm' 1 -Describe 'COM port redirection (disabled)'
    Set-RegValue $TS_POL 'fDisableLPT' 1 -Describe 'LPT port redirection (disabled)'
} else { Write-Skip "COM/LPT redirection left enabled by choice." }

# Make sure nothing has previously disabled the channels users depend on
Set-RegValue $TS_POL 'fDisableCam'          0 -Describe 'Audio & video playback redirection (allowed)'
Set-RegValue $TS_POL 'fDisableAudioCapture' 0 -Describe 'Microphone redirection (allowed)'
Set-RegValue $TS_POL 'fDisableCameraRedir'  0 -Describe 'Camera redirection (allowed)'
Set-RegValue $TS_POL 'fDisableClip'         0 -Describe 'Clipboard redirection (allowed)'
Set-RegValue $TS_POL 'fDisableCpm'          0 -Describe 'Client printer redirection (allowed)'
# The Easy Print policy stores Enabled as 3 and Disabled as 4 (TerminalServer.admx), not 1/0. Write it only when
# nothing has configured it; an explicit value is an operator, GPO or TSplus decision and printing must not change.
$ezp = Get-RegValue $TS_POL 'UseUniversalPrinterDriverFirst'
if ($null -eq $ezp -or [int]$ezp -eq 3) { Set-RegValue $TS_POL 'UseUniversalPrinterDriverFirst' 3 -Describe 'Use RD Easy Print driver first (policy Enabled = 3)' }
else { Write-Info "UseUniversalPrinterDriverFirst is already $ezp (4 = matching driver first, Easy Print as fallback) - an explicit choice, left alone." }
Set-RegValue $TS_POL 'RedirectOnlyDefaultClientPrinter' $(if ($Decisions.DefaultPrinterOnly) { 1 } else { 0 }) -Describe "Redirect only default client printer ($(if ($Decisions.DefaultPrinterOnly) {'on'} else {'off'}))"

# =====================================================================================
#  4. Session limits
# =====================================================================================

Write-Step 4 "Session limits" `
"Disconnected sessions are the usual reason a 15-user host 'feels like 30'. MaxDisconnectionTime is in milliseconds.
fResetBroken=1 logs the session off (rather than just disconnecting) when the limit is reached."

if ($Decisions.DisconnectHrs -gt 0) {
    Set-RegValue $TS_POL 'MaxDisconnectionTime' ($Decisions.DisconnectHrs * 3600000) -Describe "End disconnected sessions after $($Decisions.DisconnectHrs) h"
    Set-RegValue $TS_POL 'fResetBroken' 1 -Describe 'Log off when limit reached'
    Set-RegValue $TS_POL 'MaxIdleTime' 0 -Describe 'Idle-session limit (none - disconnect limit is what matters)'
} else { Write-Skip "Disconnected-session and idle limits not set (managed by TSplus or GPO)." }
Set-RegValue $TS_POL 'fSingleSessionPerUser' $(if ($Decisions.SingleSession) { 1 } else { 0 }) -Describe "Single session per user ($(if ($Decisions.SingleSession) {'on'} else {'off'}))"

# =====================================================================================
#  5. Processor scheduling
# =====================================================================================

Write-Step 5 "Processor scheduling" `
"Win32PrioritySeparation. 0x26 gives the foreground (the user's application) shorter, boosted quanta - the
standard session-host setting. 0x18 is the Server default and favours background services such as SQL."

$sep = if ($Decisions.Sched -eq 0) { 0x26 } else { 0x18 }
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' $sep -Describe ("Win32PrioritySeparation (0x{0:x})" -f $sep)

# =====================================================================================
#  6. Windows Search
# =====================================================================================

Write-Step 6 "Windows Search indexing" `
"Restrict mode keeps the service for Start-menu/app search but stops it crawling Outlook stores, user profiles,
UNC paths and removable media. Disable mode stops the service outright."

switch ($Decisions.Search) {
    0 {
        Set-RegValue $WS_POL 'PreventIndexingOutlook'          1 -Describe 'Index Outlook (prevented)'
        Set-RegValue $WS_POL 'PreventIndexingUncPaths'         1 -Describe 'Index UNC paths (prevented)'
        Set-RegValue $WS_POL 'PreventIndexingOfflineFiles'     1 -Describe 'Index offline files (prevented)'
        Set-RegValue $WS_POL 'DisableRemovableDriveIndexing'   1 -Describe 'Index removable drives (prevented)'
        Set-RegValue $WS_POL 'PreventIndexingEmailAttachments' 1 -Describe 'Index email attachments (prevented)'
        Set-RegValue $WS_POL 'AllowIndexingEncryptedStoresOrItems' 0 -Describe 'Index encrypted items (prevented)'
        Set-RegValue "$WS_POL\PreventIndexingCertainPaths" 'file:///C:\Users\*' 'file:///C:\Users\*' -Type String -Describe 'Prevent indexing path: C:\Users\*'
        if ($Decisions.EnableSearchSvc) {
            if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
                if ($PSCmdlet.ShouldProcess('Windows Search Service feature (Search-Service)', 'Install')) {
                    $fr = Install-WindowsFeature -Name Search-Service
                    if ("$($fr.RestartNeeded)" -eq 'Yes') { Add-RebootReason 'Windows Search Service feature' }
                }
                $script:ChangeCount++
                Write-Result "Windows Search Service feature installed - WSearch service now Automatic (Delayed Start)"
                $RollbackLines.Add("Set-Service -Name 'WSearch' -StartupType Disabled -ErrorAction SilentlyContinue   # feature stays installed; Uninstall-WindowsFeature Search-Service removes it")
            } else {
                Set-ServiceState -Name 'WSearch' -StartupType Automatic -Describe 'Windows Search service'
            }
            Write-Info "Verify after a live run: Control Panel > Indexing Options > Modify should list C:\Users as excluded (the wildcard rule)."
        } elseif ($wsearchStart -eq 'Disabled') {
            Write-Info "Windows Search service left Disabled by choice. The policy keys above take effect if it is ever enabled (Install-WindowsFeature Search-Service)."
        } else {
            Write-Info "Windows Search service left $wsearchStart. Existing index entries are purged over time; 'Rebuild' in Indexing Options forces it."
        }
    }
    1 { Set-ServiceState -Name 'WSearch' -StartupType Disabled -StopNow -Describe 'Windows Search service' }
    2 { Write-Skip "Windows Search left as-is by choice." }
}

# =====================================================================================
#  7. Storage and filesystem
# =====================================================================================

Write-Step 7 "Storage and filesystem" `
"Scheduled defrag is disabled - this host lives on SSD/SAN storage and defrag is pure wear. 8.3 short-name
generation is disabled system-wide: dozens of profiles x tens of thousands of small files make it measurable.
(Only affects files created from now on.) NTFS last-access updates are already off on Server by default."

Set-ScheduledTaskState -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -Enabled $false -Describe 'Scheduled defrag task'
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 1 -Describe '8.3 short-name creation (disabled)'
Add-RebootReason '8.3 name creation setting'

# =====================================================================================
#  8. Power plan
# =====================================================================================

Write-Step 8 "Power plan" `
"High Performance. In a Hyper-V/VMware guest this mostly affects timer coalescing rather than CPU frequency - the
HOST's power plan is what governs clocks - but Balanced in the guest still adds latency under bursty load."

$hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$active = (powercfg /getactivescheme) -replace '.*GUID:\s*([0-9a-f-]+).*', '$1'
if ($active -eq $hp) { Write-Info "High Performance already active (no change)" }
else {
    if ($PSCmdlet.ShouldProcess('Power plan', "Set active scheme High Performance (was $active)")) { powercfg /setactive $hp | Out-Null }
    $script:ChangeCount++
    Write-Result "Power plan: $active -> High Performance"
    $RollbackLines.Add("powercfg /setactive $active | Out-Null")
}
if ($isVM) { Write-Info "Virtual machine: confirm the hypervisor host is also on High Performance." }

# =====================================================================================
#  9. Logon-time cruft and consumer features
# =====================================================================================

Write-Step 9 "Logon-time cruft and consumer features" `
"Everything that fires on a new user's first logon and slows every logon thereafter: the 'Hi, getting things
ready' animation, Store/Spotlight content delivery, Edge's welcome tour, and Server Manager auto-launch for admins.
Server 2025 (Windows 11 shell) is where this matters most; the keys are harmless no-ops on 2019/2022."

$POL_SYS = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$POL_CDM = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-RegValue $POL_SYS 'EnableFirstLogonAnimation' 0 -Describe 'First-logon animation (off)'
Set-RegValue $POL_CDM 'DisableWindowsConsumerFeatures' 1 -Describe 'Windows consumer features (off)'
Set-RegValue $POL_CDM 'DisableSoftLanding' 1 -Describe 'Tips/suggestions (off)'
Set-RegValue $POL_CDM 'DisableWindowsSpotlightFeatures' 1 -Describe 'Windows Spotlight (off)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1 -Describe 'Edge first-run experience (hidden)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0 -Describe 'Edge startup boost (off - one less background process per user)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0 -Describe 'Edge background mode (off)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0 -Describe 'News & interests / widgets (off)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 -Describe 'Web results in Start search (off)'
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\ServerManager' 'DoNotOpenServerManagerAtLogon' 1 -Describe 'Server Manager at logon (off)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1 -Describe 'Lock screen (off - one less draw on connect)'
if ($build -ge 26100) {
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 -Describe 'Windows Copilot (off)'
    Set-RegValue $WS_POL 'EnableDynamicContentInWSB' 0 -Describe 'Search highlights / dynamic content in search box (off)'
}

# Default-user hive content-delivery keys (so new profiles never download suggestions)
$DefaultHive = 'C:\Users\Default\NTUSER.DAT'
$DefaultKey  = 'HKU\RDSOPT_DEFAULT'
$script:HiveFiles[$DefaultKey] = $DefaultHive
$loadedDefault = $false
if (Test-Path $DefaultHive) {
    if ($PSCmdlet.ShouldProcess('Default User hive', 'Load for editing')) {
        $r = Invoke-RegLoad $DefaultKey $DefaultHive
        if ($r.Ok) { $loadedDefault = $true } else { Write-Warn "Could not load Default User hive: $($r.Out)" }
    }
}

# =====================================================================================
# 10. Visual effects - Default User hive (and optionally existing profiles)
# =====================================================================================

Write-Step 10 "Visual effects" `
"'Best performance' with two things turned back on: font smoothing (text is unreadable without it over RDP) and
'show window contents while dragging' (otherwise RDP shows a dragged outline that lags). Animations, fades,
shadows, Aero Peek and transparency are all off - each one is extra frames the encoder has to ship."

function Set-VfxInHive {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Root, [string]$Label)   # $Root like 'HKU\RDSOPT_DEFAULT' (reg-style path)
    $r = "Registry::$Root"
    Set-RegValue "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 2 -Describe "$Label : VisualFXSetting (best performance)"
    Set-RegValue "$r\Control Panel\Desktop" 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -Describe "$Label : UserPreferencesMask (perf + font smoothing)"
    Set-RegValue "$r\Control Panel\Desktop" 'FontSmoothing' '2' -Type String -Describe "$Label : FontSmoothing (ClearType)"
    Set-RegValue "$r\Control Panel\Desktop" 'DragFullWindows' '1' -Type String -Describe "$Label : DragFullWindows (on)"
    Set-RegValue "$r\Control Panel\Desktop" 'MenuShowDelay' '0' -Type String -Describe "$Label : MenuShowDelay (0)"
    Set-RegValue "$r\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '0' -Type String -Describe "$Label : Min/max animations (off)"
    Set-RegValue "$r\Software\Microsoft\Windows\DWM" 'EnableAeroPeek' 0 -Describe "$Label : Aero Peek (off)"
    Set-RegValue "$r\Software\Microsoft\Windows\DWM" 'AlwaysHibernateThumbnails' 0 -Describe "$Label : Thumbnail hibernation (off)"
    Set-RegValue "$r\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency' 0 -Describe "$Label : Transparency (off)"
    Set-RegValue "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAnimations' 0 -Describe "$Label : Taskbar animations (off)"
    Set-RegValue "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ListviewShadow' 0 -Describe "$Label : Icon label shadows (off)"
    Set-RegValue "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'IconsOnly' 1 -Describe "$Label : Thumbnails in Explorer (icons only)"
    # Content delivery (per-user side of step 9)
    $cdm = "$r\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    foreach ($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','SoftLandingEnabled') {
        Set-RegValue $cdm $n 0 -Describe "$Label : $n"
    }
}

if ($loadedDefault) {
    try { Set-VfxInHive $DefaultKey 'Default User' } finally { $null = Invoke-RegUnload $DefaultKey }
    Write-Result "Default User hive updated - all NEW profiles inherit these settings."
} elseif ($DryRun -and (Test-Path $DefaultHive)) {
    Write-Info "(dry run) C:\Users\Default\NTUSER.DAT is not loaded in a dry run, so current values are unknown. A live run sets:"
    Set-VfxInHive $DefaultKey 'Default User'
} else { Write-Warn "Default User hive not found at $DefaultHive - new-profile defaults not applied." }

if ($Decisions.VfxExisting) {
    $loadedSids = (Get-ChildItem Registry::HKEY_USERS | ForEach-Object { $_.PSChildName })
    $profiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' -and (Test-Path (Join-Path $_.LocalPath 'NTUSER.DAT')) }
    $done = 0; $skipped = 0
    foreach ($p in $profiles) {
        $name = Split-Path $p.LocalPath -Leaf
        if ($loadedSids -contains $p.SID) { Write-Info "$name is logged on - hive in use, skipped (settings apply next time via GPO/logon, or re-run later)"; $skipped++; continue }
        $key = "HKU\RDSOPT_$($p.SID)"
        if ($PSCmdlet.ShouldProcess("Profile $name", 'Apply visual-effects settings')) {
            $r = Invoke-RegLoad $key (Join-Path $p.LocalPath 'NTUSER.DAT')
            if (-not $r.Ok) { Write-Info "$name : hive could not be loaded ($($r.Out)) - skipped"; $skipped++; continue }
            $script:HiveFiles[$key] = (Join-Path $p.LocalPath 'NTUSER.DAT')
            try { Set-VfxInHive $key $name; $done++ }
            finally { $null = Invoke-RegUnload $key }
        } else { $done++ }
    }
    Write-Result "Existing profiles: $done $(if ($DryRun) {'would be updated'} else {'updated'}), $skipped skipped (logged on or locked)."
} else { Write-Skip "Existing profiles left alone by choice." }

# =====================================================================================
# 11. Profile hygiene
# =====================================================================================

Write-Step 11 "Profile hygiene" `
"Deletes local profiles not used for N days at the next boot. Roaming-profile users just get their local cache
rebuilt from AD. Also stops Windows silently changing a user's default printer to the last one they printed to -
a constant source of 'my printer changed' tickets on session hosts."

if ($Decisions.ProfileCleanupDays -gt 0) {
    Set-RegValue $POL_SYS 'CleanupProfiles' $Decisions.ProfileCleanupDays -Describe "Delete profiles unused for $($Decisions.ProfileCleanupDays) days (at restart)"
} else { Write-Skip "Profile cleanup not configured by choice." }
if ($loadedDefault -or $DryRun) {
    # LegacyDefaultPrinterMode lives per-user; set it in Default User so new profiles get it.
    $ok = $DryRun
    if (-not $DryRun) { $ok = (Invoke-RegLoad $DefaultKey $DefaultHive).Ok }
    if ($ok) {
        try { Set-RegValue "Registry::$DefaultKey\Software\Microsoft\Windows NT\CurrentVersion\Windows" 'LegacyDefaultPrinterMode' 1 -Describe 'Default User : "Let Windows manage my default printer" (off)' }
        finally { if (-not $DryRun) { $null = Invoke-RegUnload $DefaultKey } }
    }
}

# =====================================================================================
# 12. Services and background noise
# =====================================================================================

Write-Step 12 "Services and background noise" `
"SysMain (Superfetch) and Windows Error Reporting are turned off by default. Nothing that RDP, TSplus, printing,
audio or networking depends on is touched."

if ($Decisions.DisableSysMain) { Set-ServiceState -Name 'SysMain' -StartupType Disabled -StopNow -Describe 'SysMain (Superfetch)' } else { Write-Skip 'SysMain left as-is.' }
if ($Decisions.DisableWER) {
    Set-ServiceState -Name 'WerSvc' -StartupType Disabled -StopNow -Describe 'Windows Error Reporting service'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 -Describe 'WER policy (disabled)'
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'DontShowUI' 1 -Describe 'WER crash dialogs (hidden)'
} else { Write-Skip 'Windows Error Reporting left as-is.' }
Set-ServiceState -Name 'DiagTrack' -StartupType Disabled -StopNow -Describe 'Connected User Experiences and Telemetry'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 -Describe 'Delivery Optimization (HTTP only, no peer caching)'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' $(if ($os.Caption -match 'Datacenter|Standard') { 0 } else { 1 }) -Describe 'Telemetry level (security/minimum)'

# =====================================================================================
# 13. Windows Update behaviour
# =====================================================================================

Write-Step 13 "Windows Update behaviour" `
"When the host patches itself. Active hours 06:00-20:00 stop restarts in the working day. The scheduled install
uses the classic AUOptions=4 day/time schedule, which Server 2019/2022/2025 still honour. 'Always restart at the
scheduled time' only works while 'no auto-restart with logged-on users' is off - they are mutually exclusive, so
each option sets both. The -InstallUpdates step at the end is separate: that is 'patch now', this is 'patch on a
schedule from now on'."

if ($Decisions.UpdateMode -le 2) {
    Set-RegValue $WU_POL 'SetActiveHours'   1  -Describe 'Active hours (enforced)'
    Set-RegValue $WU_POL 'ActiveHoursStart' 6  -Describe 'Active hours start (06:00)'
    Set-RegValue $WU_POL 'ActiveHoursEnd'   20 -Describe 'Active hours end (20:00)'
    Set-RegValue $AU_POL 'NoAutoUpdate' 0 -Describe 'Automatic Updates (on)'
}
if ($Decisions.UpdateMode -le 1) {
    Set-RegValue $AU_POL 'AUOptions' 4 -Describe 'Automatic Updates mode (4 = auto download, scheduled install)'
    Set-RegValue $AU_POL 'AutomaticMaintenanceEnabled' 0 -Describe 'Install during automatic maintenance (off - the schedule below applies)'
    Set-RegValue $AU_POL 'ScheduledInstallDay'  $UpdateDay  -Describe "Scheduled install day ($($dayNames[$UpdateDay]))"
    Set-RegValue $AU_POL 'ScheduledInstallTime' $UpdateHour -Describe ('Scheduled install time ({0:00}:00)' -f $UpdateHour)
    if ($UpdateDay -ne 0) { Set-RegValue $AU_POL 'ScheduledInstallEveryWeek' 1 -Describe 'Scheduled install every week' }
}
switch ($Decisions.UpdateMode) {
    0 {
        Set-RegValue $AU_POL 'NoAutoRebootWithLoggedOnUsers' 0 -Describe 'No auto-restart with logged-on users (off - the scheduled restart must win)'
        Set-RegValue $AU_POL 'AlwaysAutoRebootAtScheduledTime' 1 -Describe 'Always restart at the scheduled time (on)'
        Set-RegValue $AU_POL 'AlwaysAutoRebootAtScheduledTimeMinutes' 15 -Describe 'Warning before the scheduled restart (15 min)'
        Write-Info "Anyone still logged on at $window gets a 15-minute countdown, then the host restarts. The disconnected-session limit in step 4 keeps stale sessions from piling up before then."
    }
    1 {
        Set-RegValue $AU_POL 'NoAutoRebootWithLoggedOnUsers' 1 -Describe 'No auto-restart with logged-on users (on)'
        Set-RegValue $AU_POL 'AlwaysAutoRebootAtScheduledTime' 0 -Describe 'Always restart at the scheduled time (off)'
        Write-Info "The restart waits until no session - active OR disconnected - remains. One user who never logs off can hold a pending restart for weeks; the step-4 limit is what prevents that."
    }
    2 {
        Set-RegValue $AU_POL 'AUOptions' 3 -Describe 'Automatic Updates mode (3 = auto download, notify to install)'
        Set-RegValue $AU_POL 'NoAutoRebootWithLoggedOnUsers' 1 -Describe 'No auto-restart with logged-on users (on)'
        Set-RegValue $AU_POL 'AlwaysAutoRebootAtScheduledTime' 0 -Describe 'Always restart at the scheduled time (off)'
    }
    3 { Write-Skip "Windows Update behaviour left as-is (managed elsewhere)." }
}

# =====================================================================================
# 14. Defender exclusions
# =====================================================================================

Write-Step 14 "Defender exclusions" `
"Path exclusions only. Real-time protection stays on. The browser-cache paths generate thousands of tiny writes per
user per hour that Defender otherwise inspects one by one."

if ($Decisions.DefenderExcl) {
    $excl = @('C:\Users\*\AppData\Local\Microsoft\Windows\INetCache',
              'C:\Users\*\AppData\Local\Microsoft\Edge\User Data\Default\Cache',
              'C:\Users\*\AppData\Local\Google\Chrome\User Data\Default\Cache')
    foreach ($d in 'C:\Program Files (x86)\TSplus','C:\Program Files\TSplus') { if (Test-Path $d) { $excl += $d } }
    $current = @((Get-MpPreference).ExclusionPath)
    foreach ($e in $excl) {
        if ($current -contains $e) { Write-Info "Exclusion already present: $e"; continue }
        if ($PSCmdlet.ShouldProcess('Defender', "Add exclusion $e")) { Add-MpPreference -ExclusionPath $e }
        $script:ChangeCount++
        Write-Result "Exclusion added: $e"
        $RollbackLines.Add("Remove-MpPreference -ExclusionPath '$e' -ErrorAction SilentlyContinue")
    }
} else { Write-Skip "Defender exclusions not added (Defender off, not present, or declined)." }

# =====================================================================================
# 15. Things this script deliberately does NOT do (printed so the operator knows)
# =====================================================================================

Write-Step 15 "Deliberately NOT changed" `
"- RDP security: NLA, SecurityLayer, MinEncryptionLevel are untouched. There is no performance gain in lowering them.
- TCP stack 'tweaks' (TcpAckFrequency, Nagle, chimney, LSO): 2008-era folklore; neutral-to-harmful on current Server in a VM.
- DisablePagingExecutive / LargeSystemCache: folklore. Left at defaults.
- TSplus configuration: AdminTool, HTML5 gateway, Universal Printer, TSplus session timeouts.
- Firewall, listening port, RDP certificates.
- Printing: printer redirection is never disabled, the Easy Print policy is only written when nothing has set it, and
  'redirect only the default printer' defaults to whatever the host does today.
- Pagefile: review manually - a fixed-size pagefile is more predictable than system-managed on a loaded host."
Write-Info "Reviewed."

# =====================================================================================
# 16. Windows Update (opt-in)
# =====================================================================================

Write-Step 16 "Windows Update" `
"Opt-in. Uses the Windows Update Agent that ships with the OS (the same engine the Settings page uses), so it works
against Microsoft Update or your WSUS and needs no modules. Everything pending is listed first; nothing is downloaded
in a dry run. A cumulative update needs a reboot, which is added to the reboot reasons."

if ($Decisions.InstallUpdates) {
    try {
        Write-Info "Scanning Windows Update - this can take a few minutes on a host that is behind..."
        $wuSession = New-Object -ComObject Microsoft.Update.Session
        $wuSession.ClientApplicationID = 'Optimize-RDSHost'
        $wuResult  = $wuSession.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0 and BrowseOnly=0")
        $n = [int]$wuResult.Updates.Count
        if ($n -eq 0) {
            Write-Result "Nothing pending - Windows Update reports this host as current."
        } else {
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            for ($i = 0; $i -lt $n; $i++) {
                $u = $wuResult.Updates.Item($i)
                $kbs = @(); for ($j = 0; $j -lt $u.KBArticleIDs.Count; $j++) { $kbs += 'KB' + $u.KBArticleIDs.Item($j) }
                Write-Host ("     .. {0,-12} {1,6} MB  {2}" -f ($kbs -join ','), [int]($u.MaxDownloadSize / 1MB), $u.Title) -ForegroundColor DarkGray
                $null = $coll.Add($u)
            }
            $others = Get-OtherSessionCount
            if ($others -gt 0) { Write-Warn "$others other user session(s) are active - the install runs live (no reboot until you say so) but the host will be slow for a while." }
            if ($PSCmdlet.ShouldProcess('Windows Update', "Download and install $n update(s)")) {
                for ($i = 0; $i -lt $n; $i++) { $u = $coll.Item($i); if (-not $u.EulaAccepted) { $u.AcceptEula() } }
                Write-Info "Downloading $n update(s)..."
                $dl = $wuSession.CreateUpdateDownloader(); $dl.Updates = $coll
                $dr = $dl.Download()
                if ([int]$dr.ResultCode -ne 2) { throw ("download ended with result code {0} (HRESULT 0x{1:x8})" -f $dr.ResultCode, $dr.HResult) }
                Write-Info "Installing - do not close this window. A cumulative update can take 10-30 minutes."
                $inst = $wuSession.CreateUpdateInstaller(); $inst.Updates = $coll
                $ir = $inst.Install()
                $codes = @{ 2 = 'succeeded'; 3 = 'succeeded with errors'; 4 = 'FAILED'; 5 = 'aborted' }
                for ($i = 0; $i -lt $n; $i++) {
                    $rc  = [int]$ir.GetUpdateResult($i).ResultCode
                    $txt = if ($codes.ContainsKey($rc)) { $codes[$rc] } else { "result code $rc" }
                    Write-Host ("     .. {0} : {1}" -f $coll.Item($i).Title, $txt) -ForegroundColor $(if ($rc -eq 2) { 'DarkGray' } else { 'Magenta' })
                }
                if ($ir.RebootRequired) { Add-RebootReason 'Windows updates' }
                if ([int]$ir.ResultCode -eq 2) { Write-Result "$n update(s) installed." }
                else { Write-Warn "Windows Update finished with result code $($ir.ResultCode) - see Settings > Windows Update > Update history." }
                $script:ChangeCount += $n
            } else {
                Write-Result "$n pending update(s) listed - nothing downloaded or installed in a dry run."
            }
        }
    } catch {
        Write-Warn "Windows Update step did not complete: $($_.Exception.Message)"
    }
} else { Write-Skip "Windows Update not scanned (declined, or -InstallUpdates not given)." }

# =====================================================================================
#  Wrap-up
# =====================================================================================

# Write rollback script
$header = @"
# Rollback for Optimize-RDSHost run $Stamp on $env:COMPUTERNAME ($osName)
# Restores every value this run changed to its prior state. Run elevated. Reboot afterwards.
#Requires -RunAsAdministrator
`$ErrorActionPreference = 'Continue'
"@
if (-not $DryRun) {
    $body = New-Object System.Collections.Generic.List[string]
    foreach ($l in $RollbackLines) { $body.Add($l) }
    foreach ($hk in $script:HiveRollback.Keys) {
        $file = $script:HiveFiles[$hk]
        $body.Add("")
        $body.Add("# --- user hive $file (skipped if the user is logged on) ---")
        $body.Add("if ((cmd /c `"reg load `"`"$hk`"`" `"`"$file`"`" 2>&1`") -and `$LASTEXITCODE -eq 0) {")
        foreach ($l in $script:HiveRollback[$hk]) { $body.Add("    $l") }
        $body.Add("    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300; `$null = cmd /c `"reg unload `"`"$hk`"`" 2>&1`"")
        $body.Add("} else { Write-Warning `"Hive $file is in use (user logged on) - rerun this rollback later to restore it.`" }")
    }
    ($header + "`n" + ($body -join "`n") + "`nWrite-Host 'Rollback complete - reboot to apply.' -ForegroundColor Yellow`n") | Set-Content -Path $Rollback -Encoding UTF8
}

Write-Banner "Summary"
Write-Host ("  Host           : {0}  ({1} build {2}.{3})" -f $env:COMPUTERNAME, $osName, $build, $ubr)
Write-Host ("  Changes made   : {0}{1}" -f $ChangeCount, $(if ($DryRun) { '  (dry run - nothing actually written)' } else { '' }))
Write-Host ("  Warnings       : {0}" -f $WarnCount) -ForegroundColor $(if ($WarnCount) { 'Magenta' } else { 'Gray' })
Write-Host ("  Rollback       : {0}" -f $(if ($DryRun) { 'not written (dry run)' } else { $Rollback }))
Write-Host ("  Log            : {0}" -f $(if ($DryRun) { 'not written (dry run)' } else { $LogFile }))
Write-Host ''
Write-Host "  Decisions applied:" -ForegroundColor Cyan
foreach ($k in $Decisions.Keys) { Write-Host ("    {0,-20} {1}" -f $k, $Decisions[$k]) }
Write-Host ''
Write-Host "  What takes effect when:" -ForegroundColor Cyan
Write-Host "    Immediately      : service changes, Defender exclusions, power plan, Windows Update policy"
Write-Host "    Next RDP connect : all Terminal Services policy keys (graphics, transport, redirection, session limits)"
Write-Host "    Next user logon  : visual effects, content-delivery, Edge/first-run settings"
Write-Host "    After reboot     : scheduler quantum$(if ($Decisions.ProfileCleanupDays -gt 0) { ', profile cleanup' })$(if ($RebootReasons.Count) { ', ' + ($RebootReasons -join ', ') })"
Write-Host ''
Write-Host "  Verify after reconnecting (Ctrl+Alt+End is unaffected):" -ForegroundColor Cyan
Write-Host "    - Client: click the connection-quality icon in the RDP bar -> should show UDP if enabled and the client allows it"
Write-Host "    - Server: Get-ItemProperty '$TS_POL' | Format-List"
Write-Host "    - Server: query session  (confirm disconnected sessions end after the configured window)"
if ($domainJoined) { Write-Host "    - Domain-joined: gpupdate /force, then re-run this script with -WhatIf - anything listed as changing again is owned by a GPO" }

if (-not $DryRun) { Stop-Transcript | Out-Null }

if ($RebootNeeded -and -not $NoReboot -and -not $DryRun) {
    Write-Host ''
    $others = Get-OtherSessionCount
    if ($others -gt 0) { Write-Warn "$others other user session(s) are active. Reboot out of hours." }
    if (Ask-YesNo "Reboot now to apply: $($RebootReasons -join ', ')?" $false) {
        Write-Host "  Rebooting in 15 seconds - Ctrl+C to cancel." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    } else {
        Write-Host "  Reboot deferred. Remember: $($RebootReasons -join ', ') need it." -ForegroundColor Yellow
    }
}
