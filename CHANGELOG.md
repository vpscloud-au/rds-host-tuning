# Changelog

All notable changes to this project are documented here. Versions follow [SemVer](https://semver.org): patch = safe fixes, minor = new settings or prompts, major = a changed default that could alter behaviour on an existing host.

## [1.1.0] - 2026-10-08

First version verified with a `-WhatIf` run on a real Server 2025 host (26100.6584) under Windows PowerShell 5.1. No parse or runtime errors; the changes below come from reading that output.

- **Fixed (printing):** `UseUniversalPrinterDriverFirst` was written as 1. The Group Policy definition stores Enabled as 3 and Disabled as 4, so 1 was undefined. Now writes 3, and only when nothing has configured the value; an existing operator/GPO/TSplus choice is reported and left alone.
- **Fixed:** `MaxIdleTime` was zeroed even when the operator chose to leave session limits to TSplus/GPO. It is now only written when the script manages the limits.
- **Changed (default):** Restrict mode for Windows Search no longer flips a Disabled `WSearch` service to Automatic. If the service is Disabled (the Search Service feature was never installed) you are asked, default No; a Yes installs the `Search-Service` feature. Unattended runs leave the service as it is.
- **Changed (default):** processor scheduling defaults to foreground (0x26) even when a local SQL instance is detected; the SQL note stays in the prompt and 0x18 is still one keypress away.
- **Changed (default):** "redirect only the default client printer" now defaults to the host's current setting instead of No, so printing behaviour never changes unless you choose it.
- **Added:** a patch-now step and `-SkipUpdates`. By default the run scans with the built-in Windows Update Agent (COM, no modules), lists pending updates, and installs them as the last step; interactive runs ask (default Yes). `-WhatIf` only lists. Covers the Server 2025 RDP freeze fix without hard-coding a KB.
- **Changed (defaults, from the first domain-joined dry run):** disconnected sessions end after 4 h by default even when TSplus is detected (answer 0 to leave it to TSplus); Windows Update behaviour defaults to install-in-window with the restart deferred until nobody is logged on.
- **Added:** session-limit, single-session and default-printer prompts show the host's current values, with a nudge when a disconnected-session limit is under 10 minutes (TSplus AdminTool writes the same registry values).
- **Added:** Windows Update behaviour prompt replacing the fixed "no auto-reboot + active hours" step: install and restart in a maintenance window (default Sunday 03:00; `-UpdateDay`, `-UpdateHour`) with a 15-minute warning, or restart only when nobody is logged on, or download-and-notify, or leave as-is. Active hours 06-20 stay in every case but the last.
- **Added:** Group Policy awareness. The script reads the `registry.pol` of every GPO applied to the machine, reports how many values are GPO-controlled in the detection block, and skips each one with a warning naming the GPO instead of writing a value the next refresh would undo. Domain membership is shown too. README gains a section on domain-joined hosts with a GPO location table.
- **Added:** "Windows Search", "Domain" and "Group Policy" lines in the detection block.
- **Improved:** explanatory text and prompt details are word-wrapped to the console width instead of hard-wrapped at ~115 columns, which produced ragged breaks on a 120-column window.
- **Improved:** the dry run now lists every value a live run would set in the Default User hive (current values shown as unknown, since the hive is not loaded in a dry run) and says "would be updated" for existing profiles.
- **Improved:** the twelve `What if: Performing the operation "Set Alias"` lines that the CimCmdlets module printed before the banner under `-WhatIf` are gone (module is imported with WhatIf temporarily off). The dry run no longer creates `C:\ProgramData\RDSOptimize` either.
- **Improved:** registry values are read by exact name through the .NET registry API; a value name containing `*` (the Search path exclusion) is no longer treated as a wildcard, and keys that make `Get-ItemProperty` throw "Specified cast is not valid" (the Group Policy history keys do) no longer abort the run.
- Summary "After reboot" line lists profile cleanup only when it was configured.

## [1.0.1] - 2026-10-08

- Fixed: script is now pure ASCII. The 1.0.0 file contained UTF-8 em dashes which Windows PowerShell 5.1 (no BOM) decoded as smart quotes, terminating strings early and producing parse errors. PowerShell 7 was unaffected.
- README: added `Unblock-File` note for downloaded copies.

## [1.0.0] — 2026-10-08

Initial release.

- Windows Server 2019 / 2022 / 2025 detection; refuses client OS and unknown builds
- Server 2025 check for the Feb-2025 RDP freeze regression (KB5051987 → KB5055523)
- Interactive prompts for link type, UDP, frame rate, scheduler, Windows Search, session limits, COM/LPT, default-printer-only, profile cleanup, visual effects on existing profiles, Defender exclusions, SysMain, WER
- `-Unattended` (documented defaults) and `-WhatIf` (dry run) modes
- Every change recorded with prior value; rollback script and transcript written to `C:\ProgramData\RDSOptimize\`
- Detection of GPU, local SQL Server, TSplus and RD Session Host role, with defaults adjusted accordingly
