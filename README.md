# Optimize-RDSHost

Tunes a Windows Server session host for RDP / TSplus users. One PowerShell script, no dependencies, Server 2019 / 2022 / 2025.

Built for the common case: 5–15 concurrent users on a VM without a GPU, most of them connecting over WAN, running line-of-business apps. It applies the settings that measurably improve interactive feel, asks you about the ones that depend on your environment, and leaves alone anything that could break connectivity, printing, audio or video.

## Run it

Elevated PowerShell on the session host:

```powershell
# Interactive — asks ~16 questions, then runs unattended
Set-ExecutionPolicy -Scope Process Bypass -Force
& ([ScriptBlock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/vpscloud-au/rds-host-tuning/v1.1.0/Optimize-RDSHost.ps1)))

# Unattended — documented defaults (WAN-optimised, nothing that breaks connectivity)
& ([ScriptBlock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/vpscloud-au/rds-host-tuning/v1.1.0/Optimize-RDSHost.ps1))) -Unattended

# Dry run — shows every change it would make, writes nothing
& ([ScriptBlock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/vpscloud-au/rds-host-tuning/v1.1.0/Optimize-RDSHost.ps1))) -WhatIf

# Unattended but leave Windows Update alone (by default the run also installs pending updates last)
& ([ScriptBlock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/vpscloud-au/rds-host-tuning/v1.1.0/Optimize-RDSHost.ps1))) -Unattended -SkipUpdates
```

Or download it and read it first — it's one file, and you should. A downloaded copy carries the browser's "mark of the web", so unblock it once:

```powershell
Unblock-File .\Optimize-RDSHost.ps1
.\Optimize-RDSHost.ps1 -WhatIf
```

Every run writes a transcript and a **rollback script** to `C:\ProgramData\RDSOptimize\`. The rollback restores every value to exactly what it was.

## What it changes

| Area | What | Why |
|---|---|---|
| RDP graphics | No wallpaper, 24-bit colour (32 on LAN), medium image quality, balanced compression, AVC444 **not** forced | Caps encoder work; H.264 software encoding costs ~1 vCPU per session for no gain without a GPU |
| Transport | TCP + UDP, 1-minute keep-alive, auto-reconnect on | UDP is a real win on lossy WAN links; keep-alive kills zombie sessions promptly |
| Frame rate | DWM frame cap 30 → 60 fps *(prompt; default on LAN only)* | The one tweak users notice. Costs bandwidth, so WAN keeps 30 |
| Redirection | COM/LPT off *(prompt)*. Audio, mic, camera, clipboard, drives, printers **explicitly left on**. Easy Print first (policy value 3) is written only when nothing has configured it; an existing choice is left alone. "Only the default printer" *(prompt)* defaults to what the host does today | Teams/video in-session and client printing depend on these |
| Session limits | End disconnected sessions after N hours *(prompt, default 4 h, shows the current value; answer 0 to leave it to TSplus/GPO)*, one session per user | Disconnected sessions are why a 15-user host feels like 30 |
| Scheduler | `Win32PrioritySeparation` 0x26 (foreground) *(prompt; 0x18 offered when a local SQL instance is detected)* | Favours the interactive user over background services |
| Windows Search | Restrict: no Outlook, no `C:\Users`, no UNC/removable *(prompt)*. The service's startup type is left as it is; if it is Disabled you are asked (default No) before the Search Service feature is installed | Indexing every profile and OST is the classic hidden disk-I/O hog |
| Storage | Scheduled defrag off, 8.3 short names off | SSD/SAN-backed; defrag is pure wear |
| Power | High Performance | Timer coalescing in a guest; host plan still governs clocks |
| Logon cruft | First-logon animation, Store/Spotlight content delivery, Edge first-run, Server Manager auto-launch, lock screen, Copilot (2025) | Server 2025 ships the Windows 11 shell — this matters most there |
| Visual effects | Best performance + font smoothing + drag-full-windows, applied to Default User and (optionally) existing profiles | Every animation is extra frames the encoder has to ship |
| Profiles | Delete local profiles unused for N days *(prompt)*; stop Windows auto-switching default printer | Profile bloat is the slow-death mode of session hosts |
| Services | SysMain, WER, DiagTrack off; Delivery Optimization peer caching off | Desktop-tuned background noise |
| Windows Update behaviour | Install in a maintenance window *(prompt; default Sunday 03:00, `-UpdateDay` / `-UpdateHour`)* and restart once nobody is logged on *(default)*; or force the restart at the window with a 15-minute warning; or download-and-notify; or leave as-is. Active hours 06–20 in every case | A session host should patch at a predictable time and never restart in the working day. WSUS still decides *what* is approved; this decides *when* |
| Defender | Path exclusions for TSplus and browser caches *(prompt)* | Exclusions only; real-time protection stays on |
| Windows Update, install now | *(prompt, default Yes; `-SkipUpdates` to leave it alone)*: scan with the built-in Windows Update Agent, list what is pending, download and install it last. `-WhatIf` only lists | A host a year behind on cumulative updates has problems no tuning fixes (the Server 2025 RDP freeze is one). No modules, no extra downloads |

### What it deliberately does not touch

- **RDP security** — NLA, `SecurityLayer`, encryption level. No performance gain in lowering them.
- **TCP stack "tweaks"** — `TcpAckFrequency`, Nagle, chimney, LSO. 2008-era folklore; neutral-to-harmful on current Server in a VM.
- **`DisablePagingExecutive` / `LargeSystemCache`** — folklore.
- **TSplus configuration** — AdminTool, HTML5 gateway, Universal Printer, TSplus session timeouts. If TSplus is detected the script defaults to *not* setting its own session timeout so the two don't fight.
- **Firewall, listening port, certificates.**
- **Printing** — printer redirection is never disabled, the Easy Print policy is written only when absent, and "redirect only the default printer" defaults to the host's current behaviour. Prompts show the current value before you answer.

## OS detection and known issues

The script refuses to run on client Windows or unrecognised server builds, then checks:

- **Server 2025** — warns if the build is in the range hit by the February 2025 RDP freeze regression (KB5051987, 26100.3194) and not yet on the April 2025 fix (KB5055523, 26100.3775). No tuning fixes that bug; patch first.
- **Server 2022** — notes the early-2024 RD Gateway UDP 3391 issue if the host is also a gateway.
- **Server 2019** — extended-support warning.
- **Any** — warns if the last cumulative update is older than 90 days, and offers to install what is pending (see the Windows Update row above).

It also detects a dedicated GPU (leaves hardware-encode settings alone and tells you to review them), a local SQL Server instance (changes the scheduler default), TSplus, and the RD Session Host role.

## Domain-joined hosts and Group Policy

The script writes to the same `HKLM\SOFTWARE\Policies` keys that Group Policy writes to. On a domain-joined host that has consequences:

- **A GPO always wins.** Group Policy re-applies its settings at boot and roughly every 90 minutes. Any value a GPO configures is put back, whatever this script wrote. So the script reads the `registry.pol` of every GPO applied to the machine (from the Registry client-side extension's history, falling back to the local policy cache), reports in the detection block how many values are GPO-controlled, and skips each one with a warning that names the GPO. Change those in the GPO.
- **Values no GPO configures stay.** Group Policy only manages the values it is told about, so everything else the script sets persists across refreshes.
- **Per-user settings and roaming profiles.** The Default User hive edits apply when a profile is first created, roaming or not. Edits to existing local profiles are lost for roaming users at next logon when the server copy comes down; for them, use User Configuration > Preferences > Registry in a GPO instead.
- **Verify after a live run:** `gpupdate /force`, then run the script again with `-WhatIf`. Anything that shows as changing again is controlled by a GPO the script did not see.
- **For a fleet, prefer a GPO.** Put the session hosts in their own OU and build a GPO from the table below. Keep the script for standalone hosts, for a quick audit (`-WhatIf`), and for the parts a GPO cannot do (Default User hive, existing profiles, patch-now).

| Script area | Where it lives in a GPO (Computer Configuration > Policies > Administrative Templates unless noted) |
|---|---|
| RDP graphics, transport, keep-alive, redirection, Easy Print, session limits, time zone | Windows Components > Remote Desktop Services > Remote Desktop Session Host > Remote Session Environment / Connections / Device and Resource Redirection / Printer Redirection / Session Time Limits |
| Windows Search restrictions | Windows Components > Search |
| Windows Update behaviour, active hours | Windows Components > Windows Update (on 2022/2025 under *Manage end user experience* and *Legacy Policies*) |
| Consumer features, Spotlight, tips, widgets, Copilot, lock screen, first-logon animation, Start search web results | Windows Components > Cloud Content; News and interests; Windows Copilot; Control Panel > Personalization; System > Logon; Windows Components > File Explorer |
| Edge first-run, startup boost, background mode | Microsoft Edge (needs the Edge ADMX) |
| Profile cleanup | System > User Profiles > Delete user profiles older than a specified number of days on system restart |
| Delivery Optimization, telemetry, Error Reporting | Windows Components > Delivery Optimization; Data Collection and Preview Builds; Windows Error Reporting |
| Defender exclusions | Windows Components > Microsoft Defender Antivirus > Exclusions |
| Scheduler quantum, 8.3 names, DWM frame interval, Server Manager at logon, services, defrag task, power plan | No Administrative Template: Preferences > Windows Settings > Registry, and Control Panel Settings > Services / Scheduled Tasks / Power Options |
| Visual effects, content delivery, default-printer mode (per user) | User Configuration > Preferences > Windows Settings > Registry, or leave it to the Default User hive |

## Verifying it worked

After reconnecting:

- Client: the connection-quality icon in the RDP bar should show **UDP** if enabled and the client allows it.
- Server: `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' | Format-List`
- Server: `query session` after the disconnected-session window — stale sessions should be gone.
- Perceived: scrolling and window dragging in a session. That's the test that matters.

## Rolling back

```powershell
& 'C:\ProgramData\RDSOptimize\Rollback_<timestamp>.ps1'
Restart-Computer
```

Per-user hive changes are grouped in the rollback with their own `reg load` / `reg unload`; a user who is logged on is skipped and the rollback tells you to re-run it for them later.

## Contributing

Issues and PRs welcome. If it misbehaves on a build you have, include the output of the detection block at the top of the run (OS, build, GPU, TSplus, SQL) — that's usually enough to reproduce.

## Licence

MIT — see [LICENSE](LICENSE).
