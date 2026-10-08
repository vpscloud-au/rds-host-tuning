# Changelog

All notable changes to this project are documented here. Versions follow [SemVer](https://semver.org): patch = safe fixes, minor = new settings or prompts, major = a changed default that could alter behaviour on an existing host.

## [1.0.0] — 2026-10-08

Initial release.

- Windows Server 2019 / 2022 / 2025 detection; refuses client OS and unknown builds
- Server 2025 check for the Feb-2025 RDP freeze regression (KB5051987 → KB5055523)
- Interactive prompts for link type, UDP, frame rate, scheduler, Windows Search, session limits, COM/LPT, default-printer-only, profile cleanup, visual effects on existing profiles, Defender exclusions, SysMain, WER
- `-Unattended` (documented defaults) and `-WhatIf` (dry run) modes
- Every change recorded with prior value; rollback script and transcript written to `C:\ProgramData\RDSOptimize\`
- Detection of GPU, local SQL Server, TSplus and RD Session Host role, with defaults adjusted accordingly
